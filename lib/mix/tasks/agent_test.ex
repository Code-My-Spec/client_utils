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
  @queue_file "agent_test.queue.json"

  def run(argv) do
    requested_at = DateTime.utc_now()
    files = extract_files(argv)

    if locked?() do
      queue_request(files)
      wait_and_replay(files, requested_at, argv)
    else
      run_tests(files)
      process_queue()
    end
  end

  defp run_tests(files) do
    lock_data =
      Jason.encode!(%{
        started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        pid: System.pid()
      })

    File.write!(@lock_file, lock_data)

    try do
      test_argv = ["--formatter", "ClientUtils.TestFormatter" | files]
      Mix.Task.run("test", test_argv)
    after
      File.rm(@lock_file)
    end
  end

  defp process_queue do
    queue = read_queue()

    if queue != [] do
      # Consolidate all queued files
      all_files =
        queue
        |> Enum.flat_map(fn entry -> entry["files"] || [] end)
        |> Enum.uniq()

      # Clear queue before running
      File.rm(@queue_file)

      # Run consolidated tests
      run_tests(all_files)
    end
  end

  defp wait_and_replay(files, requested_at, opts) do
    Mix.shell().info("Tests running. Waiting for results...")

    TestCache.ensure_started()
    wait_for_completion(files, requested_at)

    Mix.shell().info("Results ready. Replaying...")
    replay_to_cli(files, requested_at, opts)
  end

  defp replay_to_cli(files, requested_at, opts) do
    cli_opts =
      opts
      |> Enum.filter(fn
        "--" <> _ -> false
        _ -> false
      end)
      |> Keyword.new(fn _ -> {:colors, []} end)
      |> Keyword.put_new(:colors, [])

    {:ok, cli} = GenServer.start_link(ExUnit.CLIFormatter, cli_opts)

    GenServer.cast(cli, {:suite_started, cli_opts})

    events =
      files
      |> Enum.flat_map(&TestCache.get_events_for_file(&1, requested_at))

    for event <- events do
      GenServer.cast(cli, event)
    end

    GenServer.cast(cli, {:suite_finished, %{run: 0, load: 0}})
  end

  defp wait_for_completion(files, requested_at) do
    unless TestCache.files_tested_after?(files, requested_at) do
      Process.sleep(500)
      wait_for_completion(files, requested_at)
    end
  end

  defp locked? do
    case File.read(@lock_file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"pid" => pid}} -> process_alive?(pid)
          _ -> false
        end

      {:error, _} ->
        false
    end
  end

  defp process_alive?(pid) do
    {_, exit_code} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
    exit_code == 0
  end

  defp queue_request(files) do
    queue = read_queue()

    entry = %{
      files: files,
      requested_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    updated_queue = queue ++ [entry]
    File.write!(@queue_file, Jason.encode!(updated_queue, pretty: true))
  end

  defp read_queue do
    case File.read(@queue_file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, queue} when is_list(queue) -> queue
          _ -> []
        end

      {:error, _} ->
        []
    end
  end

  defp extract_files(argv) do
    Enum.filter(argv, fn arg ->
      String.ends_with?(arg, ".exs") or String.ends_with?(arg, ".ex")
    end)
  end
end
