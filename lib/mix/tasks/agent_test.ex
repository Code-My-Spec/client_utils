defmodule Mix.Tasks.AgentTest do
  @moduledoc """
  Runs mix test with a lock file to prevent concurrent test runs.
  Queued requests block until their results are ready.

  ## Usage

      mix agent_test [options]

  All arguments are passed through to `mix test`.

  ## Examples

      mix agent_test
      mix agent_test test/my_test.exs
      mix agent_test --only integration
  """

  use Mix.Task

  require Logger

  alias ClientUtils.TestFormatter.TestCache

  @shortdoc "Runs tests with queuing support for concurrent requests"
  @default_base_dir ".code_my_spec/internal"

  defp base_dir do
    System.get_env("AGENT_TEST_DIR") ||
      Application.get_env(:client_utils, :agent_test_dir, @default_base_dir)
  end
  defp lock_file, do: Path.join(base_dir(), "agent_test.lock.json")
  defp callers_dir, do: Path.join(base_dir(), "callers")
  defp log_file, do: Path.join(base_dir(), "agent_test.log")

  def run(argv) do
    setup_logger()
    Logger.debug("run() called with argv=#{inspect(argv)}")
    requested_at = DateTime.utc_now()
    {files, opts} = extract_files_and_opts(argv)
    my_pid = System.pid()

    with :ok <- create_caller_file(my_pid, files, requested_at),
         :ok <- wait_current_run(),
         {:ok, role} <- get_role(my_pid, files, requested_at),
         :ok <- run_or_wait(role, files, opts),
         :ok <- maybe_replay_results(role, files, requested_at) do
      delete_caller_file(my_pid)
      Logger.debug("run() complete")
      :ok
    end
  end

  defp setup_logger do
    File.mkdir_p!(base_dir())
    Logger.add_backend({LoggerFileBackend, :file_log})

    Logger.configure_backend({LoggerFileBackend, :file_log},
      path: log_file(),
      level: :debug,
      format: "$time $metadata[$level] $message\n",
      metadata: [:pid, :mfa]
    )
  end

  # Step 1: Register ourselves as a caller
  defp create_caller_file(pid, files, requested_at) do
    Logger.debug("create_caller_file() pid=#{pid} files=#{inspect(files)}")
    File.mkdir_p!(callers_dir())

    caller_data =
      Jason.encode!(%{
        pid: pid,
        files: files,
        requested_at: DateTime.to_iso8601(requested_at)
      })

    File.write!(caller_file_path(pid), caller_data)
    :ok
  end

  # Step 2: Wait for any current test run to finish
  defp wait_current_run do
    case get_locker_pid() do
      nil ->
        Logger.debug("wait_current_run() no current run")
        :ok

      locker_pid ->
        Logger.debug("wait_current_run() waiting for #{locker_pid}")
        wait_for_process(locker_pid)
    end
  end

  defp get_locker_pid do
    case File.read(lock_file()) do
      {:error, :enoent} ->
        nil

      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"pid" => pid}} -> if process_alive?(pid), do: pid, else: nil
          _ -> nil
        end
    end
  end

  defp wait_for_process(locker_pid) do
    if process_alive?(locker_pid) do
      Process.sleep(100)
      wait_for_process(locker_pid)
    else
      Logger.debug("wait_for_process() #{locker_pid} finished")
      :ok
    end
  end

  # Step 3: Acquire lock - we're either runner or waiter
  # Key insight: if cache already has events for our files, become waiter
  defp get_role(my_pid, files, requested_at) do
    case File.read(lock_file()) do
      {:error, :enoent} ->
        # No lock - check if cache already has our results
        maybe_become_runner_or_waiter(my_pid, files, requested_at)

      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"pid" => pid}} when pid == my_pid ->
            # We already have the lock (shouldn't happen but handle it)
            Logger.debug("get_role() already have lock, runner")
            {:ok, :runner}

          {:ok, %{"pid" => locker_pid}} ->
            if process_alive?(locker_pid) do
              # Someone else got it first - we're a waiter
              Logger.debug("get_role() lock held by #{locker_pid}, becoming waiter")
              {:ok, :waiter}
            else
              # Stale lock - check cache before taking
              maybe_become_runner_or_waiter(my_pid, files, requested_at)
            end

          _ ->
            # Invalid lock - check cache before taking
            maybe_become_runner_or_waiter(my_pid, files, requested_at)
        end
    end
  end

  # Check if cache has events for all our files; if so, become waiter
  defp maybe_become_runner_or_waiter(my_pid, files, requested_at) do
    cond do
      # Empty files = "all tests" - must run
      files == [] ->
        Logger.debug("get_role() no lock, all files requested, becoming runner")
        write_lock_file(my_pid, files)
        {:ok, :runner}

      # Specific files - check if cache covers them
      files_covered_by_cache?(files, requested_at) ->
        Logger.debug("get_role() no lock but cache covers our files, becoming waiter")
        {:ok, :waiter}

      # Not covered - become runner
      true ->
        Logger.debug("get_role() no lock, files not in cache, becoming runner")
        write_lock_file(my_pid, files)
        {:ok, :runner}
    end
  end

  # Cache is valid if files were tested within the last 60 seconds
  @cache_validity_seconds 60

  defp files_covered_by_cache?(files, _requested_at) do
    cache_cutoff = DateTime.add(DateTime.utc_now(), -@cache_validity_seconds, :second)

    Enum.all?(files, fn file ->
      events = TestCache.get_events_for_file(file, cache_cutoff)
      length(events) > 0
    end)
  end

  defp write_lock_file(pid, files) do
    lock_data =
      Jason.encode!(%{
        pid: pid,
        files: files,
        started_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    File.write!(lock_file(), lock_data)
  end

  # Step 4: Run tests if we're the runner
  defp run_or_wait(:runner, files, opts) do
    Logger.debug("run_or_wait() runner, running tests with files=#{inspect(files)}")

    try do
      # Pass through all original options, adding our formatter
      test_argv = opts ++ ["--formatter", "ClientUtils.TestFormatter"] ++ files
      Logger.debug("run_or_wait() calling Mix.Tasks.Test.run with #{inspect(test_argv)}")
      # Call the test task directly to bypass any aliases
      Mix.Tasks.Test.run(test_argv)
      Logger.debug("run_or_wait() tests complete")
      :ok
    after
      File.rm(lock_file())
      Logger.debug("run_or_wait() lock released")
    end
  end

  defp run_or_wait(:waiter, _files, _opts) do
    Logger.debug("run_or_wait() waiter, skipping test run")
    :ok
  end

  # Step 5: Replay results from the events cache (only for waiters)
  defp maybe_replay_results(:runner, _files, _requested_at) do
    # Runner already saw output from the test run
    Logger.debug("maybe_replay_results() runner, skipping replay")
    :ok
  end

  defp maybe_replay_results(:waiter, files, _requested_at) do
    cache_cutoff = DateTime.add(DateTime.utc_now(), -@cache_validity_seconds, :second)

    events =
      if files == [] do
        TestCache.get_events_after(cache_cutoff)
      else
        Enum.flat_map(files, &TestCache.get_events_for_file(&1, cache_cutoff))
      end

    Logger.debug("maybe_replay_results() waiter, found #{length(events)} events")

    if events != [] do
      replay_to_cli(events)
    end

    :ok
  end

  defp replay_to_cli(events) do
    Logger.debug("replay_to_cli() replaying #{length(events)} events")

    cli_opts = [
      colors: [],
      slowest: 0,
      slowest_modules: 0,
      seed: 0,
      trace: false,
      width: 80
    ]

    {:ok, cli} = GenServer.start_link(ExUnit.CLIFormatter, cli_opts)

    GenServer.cast(cli, {:suite_started, cli_opts})

    for event <- events do
      GenServer.cast(cli, event)
    end

    GenServer.cast(cli, {:suite_finished, %{run: 0, load: 0, async: 0}})
  end

  # Caller file management
  defp caller_file_path(pid), do: Path.join(callers_dir(), "#{pid}.json")
  defp delete_caller_file(pid), do: File.rm(caller_file_path(pid))

  # Utilities
  defp process_alive?(pid) do
    {_, exit_code} = System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true)
    exit_code == 0
  end

  defp extract_files_and_opts(argv) do
    {files, opts} =
      Enum.split_with(argv, fn arg ->
        String.ends_with?(arg, ".exs") or String.ends_with?(arg, ".ex")
      end)

    {Enum.map(files, &Path.expand/1), opts}
  end
end
