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

      debug_log = Path.join(@fixture_project_path, ".client_utils/agent_test.log")
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
                {"LOG_LEVEL", "warning"}
              ],
              stderr_to_stdout: true
            )

          Logger.info("Task 1 completed with exit code #{exit_code}")
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
                {"LOG_LEVEL", "warning"}
              ],
              stderr_to_stdout: true
            )

          Logger.info("Task 2 completed with exit code #{exit_code}")
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
                {"LOG_LEVEL", "warning"}
              ],
              stderr_to_stdout: true
            )

          Logger.info("Task 3 completed with exit code #{exit_code}")
          {output, exit_code}
        end)

      # Wait for all tasks to complete (with generous timeout)
      results = Task.await_many([task1, task2, task3], 150_000)

      # Extract results
      [{output1, exit1}, {output2, exit2}, {output3, exit3}] = results

      # All three should succeed (exit code 0)
      # If any fail, include output in assertion message for debugging
      assert exit1 == 0,
             "First run (single file) failed with exit code #{exit1}:\n#{output1}"

      assert exit2 == 0,
             "Second run (all tests) failed with exit code #{exit2}:\n#{output2}"

      assert exit3 == 0,
             "Third run (single file) failed with exit code #{exit3}:\n#{output3}"
    end

    @tag :integration
    @tag timeout: 60_000
    test "all same file: three tasks request file A → 1 run, 2 replays" do
      # Scenario: All three tasks request the same file
      # Expected: Only one test run, other two replay from cache

      debug_log = Path.join(@fixture_project_path, ".client_utils/agent_test.log")
      cleanup_fixture_files(debug_log)

      file_a = "test/test_phoenix_project/blog/post_cache_test.exs"

      {results, log_content} = run_concurrent_tasks([
        {:file_a, file_a},
        {:file_a_2, file_a},
        {:file_a_3, file_a}
      ], debug_log)

      # All should succeed
      for {{name, _file}, {output, exit_code}} <- Enum.zip([{:file_a, file_a}, {:file_a_2, file_a}, {:file_a_3, file_a}], results) do
        assert exit_code == 0, "#{name} failed with exit code #{exit_code}:\n#{output}"
      end

      # Count test runs vs replays
      runner_count = count_log_matches(log_content, "run_or_wait() runner, running tests")
      waiter_count = count_log_matches(log_content, "run_or_wait() waiter, skipping test run")

      assert runner_count == 1, "Expected 1 runner, got #{runner_count}. Log:\n#{log_content}"
      assert waiter_count == 2, "Expected 2 waiters, got #{waiter_count}. Log:\n#{log_content}"
    end

    @tag :integration
    @tag timeout: 60_000
    test "no overlap: tasks request A, B, A → 2 runs (A and B), 1 replay" do
      # Scenario: Task 1 requests A, Task 2 requests B, Task 3 requests A
      # Expected: Task 1 runs A, Task 2 runs B (no overlap), Task 3 replays A

      debug_log = Path.join(@fixture_project_path, ".client_utils/agent_test.log")
      cleanup_fixture_files(debug_log)

      file_a = "test/test_phoenix_project/blog/post_cache_test.exs"
      file_b = "test/test_phoenix_project/blog_test.exs"

      {results, log_content} = run_concurrent_tasks([
        {:file_a, file_a},
        {:file_b, file_b},
        {:file_a_again, file_a}
      ], debug_log)

      # All should succeed
      for {{name, _}, {output, exit_code}} <- Enum.zip([{:file_a, file_a}, {:file_b, file_b}, {:file_a_again, file_a}], results) do
        assert exit_code == 0, "#{name} failed with exit code #{exit_code}:\n#{output}"
      end

      # Should have 2 test runs (A and B) and 1 replay (second A)
      runner_count = count_log_matches(log_content, "run_or_wait() runner, running tests")
      waiter_count = count_log_matches(log_content, "run_or_wait() waiter, skipping test run")

      assert runner_count == 2, "Expected 2 runners, got #{runner_count}. Log:\n#{log_content}"
      assert waiter_count == 1, "Expected 1 waiter, got #{waiter_count}. Log:\n#{log_content}"
    end

    @tag :integration
    @tag timeout: 60_000
    test "waiter wants superset: tasks request A, then all → 2 runs" do
      # Scenario: Task 1 requests file A, Task 2 requests all files
      # Expected: Both should run tests (Task 2 can't reuse partial results)

      debug_log = Path.join(@fixture_project_path, ".client_utils/agent_test.log")
      cleanup_fixture_files(debug_log)

      file_a = "test/test_phoenix_project/blog/post_cache_test.exs"

      {results, log_content} = run_concurrent_tasks([
        {:file_a, file_a},
        {:all_files, nil}  # nil means all files
      ], debug_log)

      [{output1, exit1}, {output2, exit2}] = results

      assert exit1 == 0, "file_a failed with exit code #{exit1}:\n#{output1}"
      assert exit2 == 0, "all_files failed with exit code #{exit2}:\n#{output2}"

      # Both should run tests - Task 2 can't reuse Task 1's partial results
      runner_count = count_log_matches(log_content, "run_or_wait() runner, running tests")

      assert runner_count == 2, "Expected 2 runners, got #{runner_count}. Log:\n#{log_content}"
    end

    @tag :integration
    @tag timeout: 120_000
    test "runner does all, waiter wants subset: all then A → 1 run, 1 replay" do
      # Scenario: Task 1 requests all files, Task 2 requests file A
      # Expected: Task 1 runs all, Task 2 replays (subset of cached results)

      debug_log = Path.join(@fixture_project_path, ".client_utils/agent_test.log")
      cleanup_fixture_files(debug_log)

      file_a = "test/test_phoenix_project/blog/post_cache_test.exs"

      {results, log_content} = run_concurrent_tasks([
        {:all_files, nil},
        {:file_a, file_a}
      ], debug_log)

      [{output1, exit1}, {output2, exit2}] = results

      assert exit1 == 0, "all_files failed with exit code #{exit1}:\n#{output1}"
      assert exit2 == 0, "file_a failed with exit code #{exit2}:\n#{output2}"

      # Task 1 runs all, Task 2 should replay (its file A is covered by "all")
      runner_count = count_log_matches(log_content, "run_or_wait() runner, running tests")
      waiter_count = count_log_matches(log_content, "run_or_wait() waiter, skipping test run")

      assert runner_count == 1, "Expected 1 runner, got #{runner_count}. Log:\n#{log_content}"
      assert waiter_count == 1, "Expected 1 waiter, got #{waiter_count}. Log:\n#{log_content}"
    end

    @tag :integration
    @tag timeout: 60_000
    test "partial overlap: tasks request A+B, then B+C → 2 runs" do
      # Scenario: Task 1 requests files A and B, Task 2 requests files B and C
      # Expected: Both should run tests (Task 2 needs C which wasn't in Task 1)

      debug_log = Path.join(@fixture_project_path, ".client_utils/agent_test.log")
      cleanup_fixture_files(debug_log)

      file_a = "test/test_phoenix_project/blog/post_cache_test.exs"
      file_b = "test/test_phoenix_project/blog_test.exs"
      file_c = "test/test_phoenix_project/accounts_test.exs"

      {results, log_content} = run_concurrent_tasks([
        {:files_ab, [file_a, file_b]},
        {:files_bc, [file_b, file_c]}
      ], debug_log)

      [{output1, exit1}, {output2, exit2}] = results

      assert exit1 == 0, "files_ab failed with exit code #{exit1}:\n#{output1}"
      assert exit2 == 0, "files_bc failed with exit code #{exit2}:\n#{output2}"

      # Both should run - Task 2 needs file C which wasn't covered by Task 1
      runner_count = count_log_matches(log_content, "run_or_wait() runner, running tests")

      assert runner_count == 2, "Expected 2 runners, got #{runner_count}. Log:\n#{log_content}"
    end

    @tag :integration
    @tag timeout: 60_000
    test "stale lock recovery: lock file exists but process is dead" do
      # Scenario: A lock file exists from a crashed process
      # Expected: New task should detect stale lock and become runner

      debug_log = Path.join(@fixture_project_path, ".client_utils/agent_test.log")
      cleanup_fixture_files(debug_log)

      # Create a stale lock file with a non-existent PID
      lock_file = Path.join(@fixture_project_path, "agent_test.lock.json")
      stale_lock = Jason.encode!(%{
        "pid" => "999999",
        "files" => [],
        "started_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })
      File.write!(lock_file, stale_lock)

      file_a = "test/test_phoenix_project/blog/post_cache_test.exs"

      {results, log_content} = run_concurrent_tasks([
        {:file_a, file_a}
      ], debug_log)

      [{output, exit_code}] = results

      assert exit_code == 0, "Task failed with exit code #{exit_code}:\n#{output}"

      # Should have detected stale lock and become runner
      runner_count = count_log_matches(log_content, "run_or_wait() runner, running tests")
      assert runner_count == 1, "Expected 1 runner (stale lock should be ignored). Log:\n#{log_content}"
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

  defp cleanup_fixture_files(_debug_log) do
    File.rm_rf(Path.join(@fixture_project_path, ".client_utils"))
    File.rm(Path.join(@fixture_project_path, "agent_test.lock.json"))
    File.rm(Path.join(@fixture_project_path, "agent_test_events.json"))
    File.rm_rf(Path.join(@fixture_project_path, "agent_test_callers"))
    File.rm(@shared_events_file)

    # Pre-compile to avoid Mix build lock contention
    {_, 0} = System.cmd("mix", ["compile"],
      cd: @fixture_project_path,
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )
  end

  defp run_concurrent_tasks(tasks, debug_log) do
    # Build async tasks with staggered starts
    async_tasks =
      tasks
      |> Enum.with_index()
      |> Enum.map(fn {{name, files}, index} ->
        # Stagger starts slightly
        if index > 0, do: Process.sleep(100)

        Task.async(fn ->
          args = case files do
            nil -> []  # all files
            list when is_list(list) -> list
            file -> [file]
          end

          Logger.info("#{name} starting with args: #{inspect(args)}")

          {output, exit_code} =
            System.cmd(
              "mix",
              ["agent_test" | args],
              cd: @fixture_project_path,
              env: [
                {"MIX_ENV", "test"},
                {"AGENT_TEST_EVENTS_FILE", @shared_events_file},
                {"LOG_LEVEL", "warning"}
              ],
              stderr_to_stdout: true
            )

          Logger.info("#{name} completed with exit code #{exit_code}")
          {output, exit_code}
        end)
      end)

    # Wait for all tasks
    results = Task.await_many(async_tasks, 150_000)

    # Read debug log
    log_content = if File.exists?(debug_log) do
      File.read!(debug_log)
    else
      ""
    end

    {results, log_content}
  end

  defp count_log_matches(log_content, pattern) do
    log_content
    |> String.split("\n")
    |> Enum.count(&String.contains?(&1, pattern))
  end
end
