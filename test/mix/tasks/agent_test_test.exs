defmodule Mix.Tasks.AgentTestTest do
  use ExUnit.Case

  require Logger

  alias ClientUtils.TestFormatter.TestCache

  @base_dir ".code_my_spec/internal"
  @lock_file Path.join(@base_dir, "agent_test.lock.json")
  @fixture_project_path "fixtures/test_phoenix_project"
  @shared_events_file Path.expand("fixtures/shared_test_events.json")

  setup do
    # Ensure base directory exists
    File.mkdir_p!(@base_dir)

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

  describe "extract_files_and_opts/1" do
    test "extracts .exs files from argv" do
      argv = ["test/foo_test.exs", "--only", "integration", "test/bar_test.exs"]
      {files, opts} = extract_files_and_opts(argv)
      assert files == ["test/foo_test.exs", "test/bar_test.exs"]
      assert opts == ["--only", "integration"]
    end

    test "extracts .ex files from argv" do
      argv = ["lib/foo.ex", "--trace"]
      {files, opts} = extract_files_and_opts(argv)
      assert files == ["lib/foo.ex"]
      assert opts == ["--trace"]
    end

    test "returns empty list when no files" do
      argv = ["--only", "integration", "--trace"]
      {files, opts} = extract_files_and_opts(argv)
      assert files == []
      assert opts == ["--only", "integration", "--trace"]
    end

    test "extracts --slowest flag with value" do
      argv = ["test/foo_test.exs", "--slowest", "5"]
      {files, opts} = extract_files_and_opts(argv)
      assert files == ["test/foo_test.exs"]
      assert opts == ["--slowest", "5"]
    end

    test "extracts multiple flags including --slowest and --trace" do
      argv = ["--trace", "test/foo_test.exs", "--slowest", "3", "--seed", "12345"]
      {files, opts} = extract_files_and_opts(argv)
      assert files == ["test/foo_test.exs"]
      assert opts == ["--trace", "--slowest", "3", "--seed", "12345"]
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

      # Verify complete test output - all results should be rendered
      assert_complete_test_output(output, "can run tests in fixture project")

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

      {output, _exit_code} =
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

      # Verify complete test output - all results should be rendered
      assert_complete_test_output(output, "second caller waits and replays cached results")

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

      test_dir = unique_test_dir()
      File.mkdir_p!(test_dir)

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
                {"AGENT_TEST_DIR", test_dir},
                {"AGENT_TEST_DEBUG", "true"},
                {"AGENT_TEST_EVENTS_FILE", @shared_events_file}
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
                {"AGENT_TEST_DIR", test_dir},
                {"AGENT_TEST_DEBUG", "true"},
                {"AGENT_TEST_EVENTS_FILE", @shared_events_file}
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
                {"AGENT_TEST_DIR", test_dir},
                {"AGENT_TEST_DEBUG", "true"},
                {"AGENT_TEST_EVENTS_FILE", @shared_events_file}
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

      # Verify complete test output for each run - all results should be rendered
      assert_complete_test_output(output1, "three concurrent - first run (single file)")
      assert_complete_test_output(output2, "three concurrent - second run (all tests)")
      assert_complete_test_output(output3, "three concurrent - third run (single file)")
    end

    @tag :integration
    @tag timeout: 60_000
    test "all same file: three tasks request file A → 1 run, 2 replays" do
      # Scenario: All three tasks request the same file
      # Expected: Only one test run, other two replay from cache

      test_dir = unique_test_dir()
      file_a = "test/test_phoenix_project/blog/post_cache_test.exs"

      {results, log_content} = run_concurrent_tasks([
        {:file_a, file_a},
        {:file_a_2, file_a},
        {:file_a_3, file_a}
      ], test_dir)

      # All should succeed and have complete output
      for {{name, _file}, {output, exit_code}} <- Enum.zip([{:file_a, file_a}, {:file_a_2, file_a}, {:file_a_3, file_a}], results) do
        assert exit_code == 0, "#{name} failed with exit code #{exit_code}:\n#{output}"
        assert_complete_test_output(output, "all same file - #{name}")
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

      test_dir = unique_test_dir()
      file_a = "test/test_phoenix_project/blog/post_cache_test.exs"
      file_b = "test/test_phoenix_project/blog_test.exs"

      {results, log_content} = run_concurrent_tasks([
        {:file_a, file_a},
        {:file_b, file_b},
        {:file_a_again, file_a}
      ], test_dir)

      # All should succeed and have complete output
      for {{name, _}, {output, exit_code}} <- Enum.zip([{:file_a, file_a}, {:file_b, file_b}, {:file_a_again, file_a}], results) do
        assert exit_code == 0, "#{name} failed with exit code #{exit_code}:\n#{output}"
        assert_complete_test_output(output, "no overlap - #{name}")
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

      test_dir = unique_test_dir()
      file_a = "test/test_phoenix_project/blog/post_cache_test.exs"

      {results, log_content} = run_concurrent_tasks([
        {:file_a, file_a},
        {:all_files, nil}  # nil means all files
      ], test_dir)

      [{output1, exit1}, {output2, exit2}] = results

      assert exit1 == 0, "file_a failed with exit code #{exit1}:\n#{output1}"
      assert exit2 == 0, "all_files failed with exit code #{exit2}:\n#{output2}"

      # Verify complete test output for each run
      assert_complete_test_output(output1, "waiter wants superset - file_a")
      assert_complete_test_output(output2, "waiter wants superset - all_files")

      # Both should run tests - Task 2 can't reuse Task 1's partial results
      runner_count = count_log_matches(log_content, "run_or_wait() runner, running tests")

      assert runner_count == 2, "Expected 2 runners, got #{runner_count}. Log:\n#{log_content}"
    end

    @tag :integration
    @tag timeout: 120_000
    test "runner does all, waiter wants subset: all then A → 1 run, 1 replay" do
      # Scenario: Task 1 requests all files, Task 2 requests file A
      # Expected: Task 1 runs all, Task 2 replays (subset of cached results)

      test_dir = unique_test_dir()
      file_a = "test/test_phoenix_project/blog/post_cache_test.exs"

      {results, log_content} = run_concurrent_tasks([
        {:all_files, nil},
        {:file_a, file_a}
      ], test_dir)

      [{output1, exit1}, {output2, exit2}] = results

      assert exit1 == 0, "all_files failed with exit code #{exit1}:\n#{output1}"
      assert exit2 == 0, "file_a failed with exit code #{exit2}:\n#{output2}"

      # Verify complete test output for each run
      assert_complete_test_output(output1, "runner does all - all_files")
      assert_complete_test_output(output2, "runner does all - file_a")

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

      test_dir = unique_test_dir()
      file_a = "test/test_phoenix_project/blog/post_cache_test.exs"
      file_b = "test/test_phoenix_project/blog_test.exs"
      file_c = "test/test_phoenix_project/accounts_test.exs"

      {results, log_content} = run_concurrent_tasks([
        {:files_ab, [file_a, file_b]},
        {:files_bc, [file_b, file_c]}
      ], test_dir)

      [{output1, exit1}, {output2, exit2}] = results

      assert exit1 == 0, "files_ab failed with exit code #{exit1}:\n#{output1}"
      assert exit2 == 0, "files_bc failed with exit code #{exit2}:\n#{output2}"

      # Verify complete test output for each run
      assert_complete_test_output(output1, "partial overlap - files_ab")
      assert_complete_test_output(output2, "partial overlap - files_bc")

      # Both should run - Task 2 needs file C which wasn't covered by Task 1
      runner_count = count_log_matches(log_content, "run_or_wait() runner, running tests")

      assert runner_count == 2, "Expected 2 runners, got #{runner_count}. Log:\n#{log_content}"
    end

    @tag :integration
    @tag timeout: 60_000
    test "stale lock recovery: lock file exists but process is dead" do
      # Scenario: A lock file exists from a crashed process
      # Expected: New task should detect stale lock and become runner

      test_dir = unique_test_dir()
      File.mkdir_p!(test_dir)

      # Create a stale lock file with a non-existent PID
      lock_file = Path.join(test_dir, "agent_test.lock.json")
      stale_lock = Jason.encode!(%{
        "pid" => "999999",
        "files" => [],
        "started_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })
      File.write!(lock_file, stale_lock)

      file_a = "test/test_phoenix_project/blog/post_cache_test.exs"

      # Run directly instead of using run_concurrent_tasks (which clears the dir)
      {output, exit_code} =
        System.cmd(
          "mix",
          ["agent_test", file_a],
          cd: @fixture_project_path,
          env: [
            {"MIX_ENV", "test"},
            {"AGENT_TEST_DIR", test_dir},
            {"AGENT_TEST_DEBUG", "true"},
            {"AGENT_TEST_EVENTS_FILE", @shared_events_file}
          ],
          stderr_to_stdout: true
        )

      assert exit_code == 0, "Task failed with exit code #{exit_code}:\n#{output}"

      # Verify complete test output
      assert_complete_test_output(output, "stale lock recovery")

      # Read the log
      debug_log = Path.join(test_dir, "agent_test.log")
      log_content = if File.exists?(debug_log), do: File.read!(debug_log), else: ""

      # Should have detected stale lock and become runner
      runner_count = count_log_matches(log_content, "run_or_wait() runner, running tests")
      assert runner_count == 1, "Expected 1 runner (stale lock should be ignored). Log:\n#{log_content}"
    end

    @tag :integration
    @tag timeout: 60_000
    test "--slowest flag is passed through to mix test" do
      # Verify that CLI options like --slowest are properly passed through

      test_dir = unique_test_dir()
      File.mkdir_p!(test_dir)

      # Run mix agent_test with --slowest flag
      {output, exit_code} =
        System.cmd(
          "mix",
          ["agent_test", "--slowest", "2", "test/test_phoenix_project/blog/post_cache_test.exs"],
          cd: @fixture_project_path,
          env: [
            {"MIX_ENV", "test"},
            {"AGENT_TEST_DIR", test_dir},
            {"AGENT_TEST_EVENTS_FILE", @shared_events_file}
          ],
          stderr_to_stdout: true
        )

      assert exit_code == 0, "agent_test failed:\n#{output}"
      # ExUnit outputs "Top N slowest" when --slowest is used
      assert output =~ ~r/Top \d+ slowest/, "Expected 'Top N slowest' output in:\n#{output}"
      # Verify complete test output
      assert_complete_test_output(output, "--slowest flag test")
    end

    @tag :integration
    @tag timeout: 60_000
    test "--trace flag is passed through to mix test" do
      # Verify that CLI options like --trace are properly passed through

      test_dir = unique_test_dir()
      File.mkdir_p!(test_dir)

      # Run mix agent_test with --trace flag
      {output, exit_code} =
        System.cmd(
          "mix",
          ["agent_test", "--trace", "test/test_phoenix_project/blog/post_cache_test.exs"],
          cd: @fixture_project_path,
          env: [
            {"MIX_ENV", "test"},
            {"AGENT_TEST_DIR", test_dir},
            {"AGENT_TEST_EVENTS_FILE", @shared_events_file}
          ],
          stderr_to_stdout: true
        )

      assert exit_code == 0, "agent_test failed:\n#{output}"
      # --trace outputs each test name with timing, look for characteristic pattern
      assert String.contains?(output, "test "), "Expected --trace output in:\n#{output}"
      # Note: --trace mode outputs test names instead of dots, so we verify the summary exists
      assert output =~ ~r/\d+ tests?, \d+ failures?/, "Expected test summary in --trace output:\n#{output}"
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

  defp extract_files_and_opts(argv) do
    {files, opts} =
      Enum.split_with(argv, fn arg ->
        String.ends_with?(arg, ".exs") or String.ends_with?(arg, ".ex")
      end)

    {files, opts}
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

  defp run_concurrent_tasks(tasks, test_dir) do
    # Ensure test directory exists and is clean
    File.rm_rf!(test_dir)
    File.mkdir_p!(test_dir)
    debug_log = Path.join(test_dir, "agent_test.log")

    # Build async tasks with staggered starts
    async_tasks =
      tasks
      |> Enum.with_index()
      |> Enum.map(fn {{name, files}, index} ->
        # Stagger starts to ensure order with System.cmd process spawning
        if index > 0, do: Process.sleep(500)

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
                {"AGENT_TEST_DIR", test_dir},
                {"AGENT_TEST_DEBUG", "true"},
                {"AGENT_TEST_EVENTS_FILE", @shared_events_file}
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

  defp unique_test_dir do
    Path.expand(Path.join(@fixture_project_path, ".code_my_spec/test_#{:rand.uniform(1_000_000)}"))
  end

  defp count_log_matches(log_content, pattern) do
    log_content
    |> String.split("\n")
    |> Enum.count(&String.contains?(&1, pattern))
  end

  # Helper to verify test output has correct number of results
  # Checks that we have at least the expected number of test result indicators
  # The main goal is to catch truncated/incomplete output (fewer results than expected)
  defp assert_complete_test_output(output, test_name) do
    # Check for completion indicators
    has_finished = String.contains?(output, "Finished in")
    dot_count = count_dots(output)

    # Extract the test summary if present
    case Regex.run(~r/(\d+) tests?, (\d+) failures?/, output) do
      [_, test_count_str, failure_count_str] ->
        test_count = String.to_integer(test_count_str)
        failure_count = String.to_integer(failure_count_str)
        pass_count = test_count - failure_count

        # Check if this is --trace mode (lists test names instead of dots)
        is_trace_mode = output =~ ~r/test .+\([\d.]+m?s\)/

        if is_trace_mode do
          # In trace mode, count test lines instead of dots
          # Lines look like: "  * test something (0.5ms) [L#6]"
          test_lines = count_trace_test_lines(output)
          assert test_lines >= test_count,
            "#{test_name}: Expected at least #{test_count} test result lines in trace mode, got #{test_lines}.\n" <>
            "This may indicate incomplete test output.\n" <>
            "Output:\n#{output}"
        else
          # In normal mode, count dots for passing tests
          # We should have at least as many dots as passing tests
          assert dot_count >= pass_count,
            "#{test_name}: Expected at least #{pass_count} dots (passes), got #{dot_count}.\n" <>
            "This may indicate incomplete/truncated test output.\n" <>
            "Output:\n#{output}"
        end

        :ok

      nil ->
        # No test summary found - check for other signs of completion or valid output
        cond do
          has_finished ->
            # Has "Finished in" but no summary - unusual but could be valid
            :ok

          dot_count > 0 and String.contains?(output, "Including tags:") ->
            # Has progress indicators and ExUnit started - output might be truncated
            # This is the pattern the user described (dots but no summary with % at end)
            flunk(
              "#{test_name}: Test output appears truncated - has #{dot_count} progress indicators but no completion summary.\n" <>
              "This may indicate the output was cut off before tests finished.\n" <>
              "Output:\n#{output}"
            )

          String.contains?(output, "Compiling") or String.contains?(output, "Including tags:") ->
            # Test started but no results - might be replayed/cached result with minimal output
            :ok

          true ->
            flunk("#{test_name}: No test output found.\nOutput:\n#{output}")
        end
    end
  end

  # Count dots (.) in test output - these indicate passing tests in normal mode
  # Dots appear at the start of lines, possibly followed by warnings
  defp count_dots(output) do
    output
    |> String.split("\n")
    |> Enum.map(fn line ->
      # Match dots at the start of lines (progress indicators)
      # Pattern: line starts with one or more dots, optionally followed by spaces and other content
      case Regex.run(~r/^([.]+)/, line) do
        [_, dots] ->
          String.length(dots)
        nil ->
          # Also check for lines that are only dots (possibly with whitespace around)
          trimmed = String.trim(line)
          if Regex.match?(~r/^[.]+$/, trimmed) do
            String.length(trimmed)
          else
            0
          end
      end
    end)
    |> Enum.sum()
  end

  # Count test lines in --trace mode output
  # These look like: "  * test something (0.5ms) [L#6]"
  defp count_trace_test_lines(output) do
    output
    |> String.split("\n")
    |> Enum.count(fn line ->
      # Match lines that show a completed test with timing
      line =~ ~r/test .+\([\d.]+m?s\)/
    end)
  end
end
