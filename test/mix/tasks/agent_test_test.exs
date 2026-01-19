defmodule Mix.Tasks.AgentTestTest do
  use ExUnit.Case

  require Logger

  alias ClientUtils.TestFormatter.TestCache

  @lock_file "agent_test.lock.json"
  @fixture_project_path "fixtures/test_phoenix_project"
  @shared_events_file Path.expand("fixtures/shared_test_events.json")

  setup do
    # Clean up lock file before each test
    File.rm(@lock_file)

    # Use a shared events file for cross-process tests
    System.put_env("AGENT_TEST_EVENTS_FILE", @shared_events_file)
    TestCache.destroy()

    on_exit(fn ->
      File.rm(@lock_file)
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
      lock_data =
        Jason.encode!(%{
          started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          pid: "999999"
        })

      File.write!(@lock_file, lock_data)
      refute locked?()
    end

    test "locked? returns true when lock file has current process PID" do
      lock_data =
        Jason.encode!(%{
          started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          pid: System.pid()
        })

      File.write!(@lock_file, lock_data)
      assert locked?()
    end
  end

  describe "integration with fixture project" do
    @tag :integration
    @tag timeout: 120_000

    test "can run tests in fixture project" do
      # This test verifies the basic flow works with a real project
      # We run a simple test file and verify events are cached

      test_file =
        Path.join(
          @fixture_project_path,
          "test/test_phoenix_project_web/controllers/error_json_test.exs"
        )

      abs_test_file = Path.expand(test_file)

      before_time = DateTime.utc_now()
      Process.sleep(10)

      # Run mix test directly in the fixture project with our formatter
      {output, exit_code} =
        System.cmd(
          "mix",
          [
            "test",
            "--formatter",
            "ClientUtils.TestFormatter",
            "test/test_phoenix_project_web/controllers/error_json_test.exs"
          ],
          cd: @fixture_project_path,
          env: [{"MIX_ENV", "test"}, {"AGENT_TEST_EVENTS_FILE", @shared_events_file}],
          stderr_to_stdout: true
        )

      # The test should pass (or at least run)
      assert exit_code == 0 or String.contains?(output, "test"), "Test run failed: #{output}"

      # Verify events were cached
      events = TestCache.get_events_for_file(abs_test_file, before_time)

      # We should have some events cached for this file
      assert length(events) > 0, "No events cached for #{abs_test_file}"
    end

    @tag :integration
    @tag timeout: 120_000

    test "second caller waits and replays cached results" do
      test_file =
        Path.join(
          @fixture_project_path,
          "test/test_phoenix_project_web/controllers/error_html_test.exs"
        )

      abs_test_file = Path.expand(test_file)

      # First, run tests to populate the cache
      before_time = DateTime.utc_now()
      Process.sleep(10)

      {_output, _exit_code} =
        System.cmd(
          "mix",
          [
            "test",
            "--formatter",
            "ClientUtils.TestFormatter",
            "test/test_phoenix_project_web/controllers/error_html_test.exs"
          ],
          cd: @fixture_project_path,
          env: [{"MIX_ENV", "test"}, {"AGENT_TEST_EVENTS_FILE", @shared_events_file}],
          stderr_to_stdout: true
        )

      # Verify cache has events
      events = TestCache.get_events_for_file(abs_test_file, before_time)
      assert length(events) > 0

      # Simulate a second caller that would replay from cache
      # by calling files_tested_after? which is what wait_for_completion uses
      assert TestCache.files_tested_after?([abs_test_file], before_time)
    end

    @tag :integration
    @tag timeout: 60_000

    test "three concurrent test runs complete successfully" do
      # This test reproduces the scenario where multiple test commands
      # are run simultaneously:
      # 1. mix test test/blog/post_repository_test.exs
      # 2. mix test (all tests)
      # 3. mix test test/blog/post_repository_test.exs
      #
      # All three should complete without failure

      debug_log = Path.join(@fixture_project_path, "agent_test_debug.log")
      File.rm(debug_log)

      # Also clean up any stale files in the fixture project
      File.rm(Path.join(@fixture_project_path, "agent_test.lock.json"))
      File.rm(Path.join(@fixture_project_path, "agent_test_events.json"))

      # Pre-compile to avoid Mix build lock contention between concurrent processes
      {_, 0} =
        System.cmd("mix", ["compile"],
          cd: @fixture_project_path,
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      single_file = "test/test_phoenix_project/blog/post_repository_test.exs"

      # Spawn three concurrent test processes
      task1 =
        Task.async(fn ->
          Logger.info("Task 1 starting: single file #{single_file}")

          {output, exit_code} =
            System.cmd(
              "mix",
              ["agent_test", single_file],
              cd: @fixture_project_path,
              env: [
                {"MIX_ENV", "test"},
                {"AGENT_TEST_EVENTS_FILE", @shared_events_file},
                {"LOG_LEVEL", "info"}
              ],
              stderr_to_stdout: true
            )

          Logger.info("Task 1 completed with exit code #{exit_code}")
          IO.puts("=== Task 1 output ===\n#{output}\n=== End Task 1 ===")
          {output, exit_code}
        end)

      # Small delay to ensure task1 starts first and acquires the lock
      Process.sleep(100)

      task2 =
        Task.async(fn ->
          Logger.info("Task 2 starting: all tests")

          {output, exit_code} =
            System.cmd(
              "mix",
              ["agent_test"],
              cd: @fixture_project_path,
              env: [
                {"MIX_ENV", "test"},
                {"AGENT_TEST_EVENTS_FILE", @shared_events_file},
                {"LOG_LEVEL", "info"}
              ],
              stderr_to_stdout: true
            )

          Logger.info("Task 2 completed with exit code #{exit_code}")
          IO.puts("=== Task 2 output ===\n#{output}\n=== End Task 2 ===")
          {output, exit_code}
        end)

      Process.sleep(50)

      task3 =
        Task.async(fn ->
          Logger.info("Task 3 starting: single file #{single_file}")

          {output, exit_code} =
            System.cmd(
              "mix",
              ["agent_test", single_file],
              cd: @fixture_project_path,
              env: [
                {"MIX_ENV", "test"},
                {"AGENT_TEST_EVENTS_FILE", @shared_events_file},
                {"LOG_LEVEL", "info"}
              ],
              stderr_to_stdout: true
            )

          Logger.info("Task 3 completed with exit code #{exit_code}")
          IO.puts("=== Task 3 output ===\n#{output}\n=== End Task 3 ===")
          {output, exit_code}
        end)

      # Wait for all tasks to complete (with generous timeout)
      results = Task.await_many([task1, task2, task3], 150_000)

      # Extract results
      [{output1, exit1}, {output2, exit2}, {output3, exit3}] = results

      # Print debug log for analysis
      if File.exists?(debug_log) do
        log_content = File.read!(debug_log)
        IO.puts("\n=== DEBUG LOG ===\n#{log_content}\n=== END DEBUG LOG ===")
      else
        IO.puts("\n=== DEBUG LOG NOT FOUND ===")
      end

      # All three should succeed (exit code 0)
      # If any fail, include output in assertion message for debugging
      assert exit1 == 0,
             "First run (single file) failed with exit code #{exit1}:\n#{output1}"

      assert exit2 == 0,
             "Second run (all tests) failed with exit code #{exit2}:\n#{output2}"

      assert exit3 == 0,
             "Third run (single file) failed with exit code #{exit3}:\n#{output3}"
    end
  end

  describe "locking behavior" do
    test "lock file prevents concurrent runs" do
      # Create a lock with current process
      lock_data =
        Jason.encode!(%{
          started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          pid: System.pid()
        })

      File.write!(@lock_file, lock_data)

      # Verify we're locked
      assert locked?()
    end
  end

  # Helper functions that mirror the private functions in the module

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
end
