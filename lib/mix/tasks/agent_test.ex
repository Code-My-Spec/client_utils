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

  alias ClientUtils.TestFormatter.TestCache

  @shortdoc "Runs tests with queuing support for concurrent requests"
  @lock_file "agent_test.lock.json"
  @callers_dir "agent_test_callers"
  @debug_log "agent_test_debug.log"

  defp log(message) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    pid = System.pid()
    line = "[#{timestamp}] [PID:#{pid}] #{message}\n"
    File.write!(@debug_log, line, [:append])
  end

  def run(argv) do
    log("run() called with argv=#{inspect(argv)}")
    requested_at = DateTime.utc_now()
    files = extract_files(argv)
    my_pid = System.pid()

    with :ok <- create_caller_file(my_pid, files, requested_at),
         :ok <- wait_current_run(),
         {:ok, role} <- get_role(my_pid, files, requested_at),
         :ok <- run_or_wait(role, files),
         :ok <- maybe_replay_results(role, files, requested_at) do
      delete_caller_file(my_pid)
      log("run() complete")
      :ok
    end
  end

  # Step 1: Register ourselves as a caller
  defp create_caller_file(pid, files, requested_at) do
    log("create_caller_file() pid=#{pid} files=#{inspect(files)}")
    File.mkdir_p!(@callers_dir)

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
        log("wait_current_run() no current run")
        :ok

      locker_pid ->
        log("wait_current_run() waiting for #{locker_pid}")
        wait_for_process(locker_pid)
    end
  end

  defp get_locker_pid do
    case File.read(@lock_file) do
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
      log("wait_for_process() #{locker_pid} finished")
      :ok
    end
  end

  # Step 3: Acquire lock - we're either runner or waiter
  # Key insight: if cache already has events for our files, become waiter
  defp get_role(my_pid, files, requested_at) do
    case File.read(@lock_file) do
      {:error, :enoent} ->
        # No lock - check if cache already has our results
        maybe_become_runner_or_waiter(my_pid, files, requested_at)

      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"pid" => pid}} when pid == my_pid ->
            # We already have the lock (shouldn't happen but handle it)
            log("get_role() already have lock, runner")
            {:ok, :runner}

          {:ok, %{"pid" => locker_pid}} ->
            if process_alive?(locker_pid) do
              # Someone else got it first - we're a waiter
              log("get_role() lock held by #{locker_pid}, becoming waiter")
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
        log("get_role() no lock, all files requested, becoming runner")
        write_lock_file(my_pid, files)
        {:ok, :runner}

      # Specific files - check if cache covers them
      files_covered_by_cache?(files, requested_at) ->
        log("get_role() no lock but cache covers our files, becoming waiter")
        {:ok, :waiter}

      # Not covered - become runner
      true ->
        log("get_role() no lock, files not in cache, becoming runner")
        write_lock_file(my_pid, files)
        {:ok, :runner}
    end
  end

  defp files_covered_by_cache?(files, requested_at) do
    Enum.all?(files, fn file ->
      events = TestCache.get_events_for_file(file, requested_at)
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

    File.write!(@lock_file, lock_data)
  end

  # Step 4: Run tests if we're the runner
  defp run_or_wait(:runner, files) do
    log("run_or_wait() runner, running tests with files=#{inspect(files)}")

    try do
      test_argv = ["--formatter", "ClientUtils.TestFormatter" | files]
      log("run_or_wait() calling Mix.Tasks.Test.run with #{inspect(test_argv)}")
      # Call the test task directly to bypass any aliases
      Mix.Tasks.Test.run(test_argv)
      log("run_or_wait() tests complete")
      :ok
    after
      File.rm(@lock_file)
      log("run_or_wait() lock released")
    end
  end

  defp run_or_wait(:waiter, _files) do
    log("run_or_wait() waiter, skipping test run")
    :ok
  end

  # Step 5: Replay results from the events cache (only for waiters)
  defp maybe_replay_results(:runner, _files, _requested_at) do
    # Runner already saw output from the test run
    log("maybe_replay_results() runner, skipping replay")
    :ok
  end

  defp maybe_replay_results(:waiter, files, requested_at) do
    events =
      if files == [] do
        TestCache.get_events_after(requested_at)
      else
        Enum.flat_map(files, &TestCache.get_events_for_file(&1, requested_at))
      end

    log("maybe_replay_results() waiter, found #{length(events)} events")

    if events != [] do
      replay_to_cli(events)
    end

    :ok
  end

  defp replay_to_cli(events) do
    log("replay_to_cli() replaying #{length(events)} events")

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
  defp caller_file_path(pid), do: Path.join(@callers_dir, "#{pid}.json")
  defp delete_caller_file(pid), do: File.rm(caller_file_path(pid))

  # Utilities
  defp process_alive?(pid) do
    {_, exit_code} = System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true)
    exit_code == 0
  end

  defp extract_files(argv) do
    argv
    |> Enum.filter(&(String.ends_with?(&1, ".exs") or String.ends_with?(&1, ".ex")))
    |> Enum.map(&Path.expand/1)
  end
end
