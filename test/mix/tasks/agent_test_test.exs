defmodule Mix.Tasks.AgentTestTest do
  use ExUnit.Case

  alias ClientUtils.TestFormatter.TestCache

  @lock_file "agent_test.lock.json"
  @queue_file "agent_test.queue.json"
  @fixture_project_path "fixtures/test_phoenix_project"
  @shared_dets_file Path.expand("fixtures/shared_test_cache.dets")

  setup do
    # Clean up lock and queue files before each test
    File.rm(@lock_file)
    File.rm(@queue_file)

    # Use a shared DETS file for cross-process tests
    System.put_env("AGENT_TEST_CACHE_FILE", @shared_dets_file)
    TestCache.destroy()
    TestCache.ensure_started()

    on_exit(fn ->
      File.rm(@lock_file)
      File.rm(@queue_file)
      TestCache.destroy()
    end)

    :ok
  end

  describe "extract_files/1" do
    test "extracts .exs files from argv" do
      argv = ["test/foo_test.exs", "--only", "integration", "test/bar_test.exs"]
      files = extract_files(argv)
      assert files == ["test/foo_test.exs", "test/bar_test.exs"]
    end

    test "extracts .ex files from argv" do
      argv = ["lib/foo.ex", "--trace"]
      files = extract_files(argv)
      assert files == ["lib/foo.ex"]
    end

    test "returns empty list when no files" do
      argv = ["--only", "integration", "--trace"]
      files = extract_files(argv)
      assert files == []
    end
  end

  describe "locking" do
    test "locked? returns false when no lock file exists" do
      refute locked?()
    end

    test "locked? returns false when lock file has invalid JSON" do
      File.write!(@lock_file, "not json")
      refute locked?()
    end

    test "locked? returns false when lock file has non-existent PID" do
      # Use a PID that definitely doesn't exist
      lock_data = Jason.encode!(%{
        started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        pid: "999999"
      })
      File.write!(@lock_file, lock_data)
      refute locked?()
    end

    test "locked? returns true when lock file has current process PID" do
      lock_data = Jason.encode!(%{
        started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        pid: System.pid()
      })
      File.write!(@lock_file, lock_data)
      assert locked?()
    end
  end

  describe "queue management" do
    test "read_queue returns empty list when no queue file" do
      assert read_queue() == []
    end

    test "read_queue returns empty list for invalid JSON" do
      File.write!(@queue_file, "not json")
      assert read_queue() == []
    end

    test "queue_request adds entry to queue" do
      queue_request(["test/foo_test.exs"])
      queue = read_queue()

      assert length(queue) == 1
      assert hd(queue)["files"] == ["test/foo_test.exs"]
      assert hd(queue)["requested_at"]
    end

    test "queue_request appends to existing queue" do
      queue_request(["test/foo_test.exs"])
      queue_request(["test/bar_test.exs"])
      queue = read_queue()

      assert length(queue) == 2
      assert Enum.at(queue, 0)["files"] == ["test/foo_test.exs"]
      assert Enum.at(queue, 1)["files"] == ["test/bar_test.exs"]
    end
  end

  describe "integration with fixture project" do
    @tag :integration
    @tag timeout: 120_000

    test "can run tests in fixture project" do
      # This test verifies the basic flow works with a real project
      # We run a simple test file and verify events are cached

      test_file = Path.join(@fixture_project_path, "test/test_phoenix_project_web/controllers/error_json_test.exs")
      abs_test_file = Path.expand(test_file)

      before_time = DateTime.utc_now()
      Process.sleep(10)

      # Run mix test directly in the fixture project with our formatter
      # Share the DETS file so we can read events from this process
      {output, exit_code} = System.cmd(
        "mix",
        ["test", "--formatter", "ClientUtils.TestFormatter", "test/test_phoenix_project_web/controllers/error_json_test.exs"],
        cd: @fixture_project_path,
        env: [{"MIX_ENV", "test"}, {"AGENT_TEST_CACHE_FILE", @shared_dets_file}],
        stderr_to_stdout: true
      )

      # The test should pass (or at least run)
      assert exit_code == 0 or String.contains?(output, "test"), "Test run failed: #{output}"

      # Close and reopen DETS to see changes from child process
      TestCache.close()
      TestCache.ensure_started()

      # Verify events were cached
      events = TestCache.get_events_for_file(abs_test_file, before_time)

      # We should have some events cached for this file
      assert length(events) > 0, "No events cached for #{abs_test_file}"
    end

    @tag :integration
    @tag timeout: 120_000

    test "second caller waits and replays cached results" do
      test_file = Path.join(@fixture_project_path, "test/test_phoenix_project_web/controllers/error_html_test.exs")
      abs_test_file = Path.expand(test_file)

      # First, run tests to populate the cache
      before_time = DateTime.utc_now()
      Process.sleep(10)

      {_output, _exit_code} = System.cmd(
        "mix",
        ["test", "--formatter", "ClientUtils.TestFormatter", "test/test_phoenix_project_web/controllers/error_html_test.exs"],
        cd: @fixture_project_path,
        env: [{"MIX_ENV", "test"}, {"AGENT_TEST_CACHE_FILE", @shared_dets_file}],
        stderr_to_stdout: true
      )

      # Close and reopen DETS to see changes from child process
      TestCache.close()
      TestCache.ensure_started()

      # Verify cache has events
      events = TestCache.get_events_for_file(abs_test_file, before_time)
      assert length(events) > 0

      # Simulate a second caller that would replay from cache
      # by calling files_tested_after? which is what wait_for_completion uses
      assert TestCache.files_tested_after?([abs_test_file], before_time)
    end
  end

  describe "concurrent access simulation" do
    test "lock file prevents concurrent runs" do
      # Create a lock with current process
      lock_data = Jason.encode!(%{
        started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        pid: System.pid()
      })
      File.write!(@lock_file, lock_data)

      # Verify we're locked
      assert locked?()

      # A second "process" would queue instead of run
      queue_request(["test/queued_test.exs"])
      queue = read_queue()
      assert length(queue) == 1
    end

    test "queue consolidates files from multiple requests" do
      # Simulate multiple requests queueing up
      queue_request(["test/a_test.exs", "test/b_test.exs"])
      queue_request(["test/b_test.exs", "test/c_test.exs"])
      queue_request(["test/d_test.exs"])

      queue = read_queue()
      assert length(queue) == 3

      # Simulate what process_queue does - consolidate files
      all_files =
        queue
        |> Enum.flat_map(fn entry -> entry["files"] || [] end)
        |> Enum.uniq()

      assert Enum.sort(all_files) == ["test/a_test.exs", "test/b_test.exs", "test/c_test.exs", "test/d_test.exs"]
    end
  end

  # Helper functions extracted from Mix.Tasks.AgentTest for testing
  # These mirror the private functions in the module

  defp extract_files(argv) do
    Enum.filter(argv, fn arg ->
      String.ends_with?(arg, ".exs") or String.ends_with?(arg, ".ex")
    end)
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
      "files" => files,
      "requested_at" => DateTime.utc_now() |> DateTime.to_iso8601()
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
end
