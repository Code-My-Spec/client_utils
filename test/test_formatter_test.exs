defmodule ClientUtils.TestFormatterTest do
  use ExUnit.Case
  import ClientUtils.TestFormatter.JsonFormatter

  alias ClientUtils.TestFormatter.TestCache

  setup do
    TestCache.ensure_started()
    TestCache.clear()
    :ok
  end

  describe "JsonFormatter" do
    test "formats passing test" do
      test = %ExUnit.Test{case: TestModule, name: :"should test"}

      assert format_test_pass(test) ==
               %{"title" => "should test", "fullTitle" => "TestModule: should test"}
    end

    test "formats failing test" do
      failures = [
        {:error, catch_error(raise "\"oops\""), []},
        {:error, catch_error(raise "oops"), []}
      ]

      test = %ExUnit.Test{
        case: TestModule,
        name: :"should test",
        tags: %{file: __ENV__.file, line: 1},
        state: {:failed, failures}
      }

      message = "\nFailure #1\n** (RuntimeError) \"oops\"\nFailure #2\n** (RuntimeError) oops"

      assert format_test_failure(test, failures) ==
               %{
                 "title" => "should test",
                 "fullTitle" => "TestModule: should test",
                 "error" => %{
                   "file" => "test/test_formatter_test.exs",
                   "line" => 1,
                   "message" => message
                 }
               }
    end

    test "formats failing test case" do
      failures = [{:error, catch_error(raise "oops"), []}, {:error, catch_error(raise "oops"), []}]

      test = %ExUnit.Test{
        case: TestModule,
        name: :"should test",
        tags: %{file: __ENV__.file, line: 1}
      }

      test_case = %ExUnit.TestCase{name: TestModule, state: {:failed, failures}, tests: [test]}
      message = "\nFailure #1\n** (RuntimeError) oops\nFailure #2\n** (RuntimeError) oops"

      assert format_test_case_failure(test_case, failures) ==
               %{
                 "title" => "TestModule: failure on setup_all callback",
                 "fullTitle" => "TestModule: failure on setup_all callback",
                 "error" => %{"file" => "test/test_formatter_test.exs", "message" => message}
               }
    end

    test "formats pending test" do
      test = %ExUnit.Test{case: TestModule, name: :"should test"}

      assert format_test_pending(test) ==
               %{"title" => "should test", "fullTitle" => "TestModule: should test", "pending" => true}
    end

    test "formats suite start event" do
      start_time = ~N[2024-01-15 10:30:00]

      assert format_suite_start_event(start_time) == %{
               "type" => "suite:start",
               "start" => "2024-01-15T10:30:00"
             }
    end

    test "formats suite end event" do
      stats = %{"passes" => 5, "failures" => 1}

      assert format_suite_end_event(stats) == %{
               "type" => "suite:end",
               "stats" => stats
             }
    end

    test "formats test event" do
      test_result = %{"title" => "my test"}

      assert format_test_event("test:pass", test_result) == %{
               "type" => "test:pass",
               "test" => test_result
             }
    end
  end

  describe "TestFormatter.init/1" do
    test "initializes with default values" do
      {:ok, config} = ClientUtils.TestFormatter.init([])

      assert config.pass_counter == 0
      assert config.failure_counter == 0
      assert config.skipped_counter == 0
      assert config.invalid_counter == 0
      assert config.case_counter == 0
      assert config.tests == []
      assert config.failures == []
      assert config.pending == []
      assert config.events == []
      assert is_pid(config.cli_formatter)
    end

    test "reads output_file from options" do
      {:ok, config} = ClientUtils.TestFormatter.init(output_file: "/tmp/test.json")
      assert config.output_file == "/tmp/test.json"
    end

    test "reads output_file from environment variable" do
      original_value = System.get_env("EXUNIT_JSON_OUTPUT_FILE")
      System.put_env("EXUNIT_JSON_OUTPUT_FILE", "/tmp/env_test.json")

      {:ok, config} = ClientUtils.TestFormatter.init([])
      assert config.output_file == "/tmp/env_test.json"

      if original_value do
        System.put_env("EXUNIT_JSON_OUTPUT_FILE", original_value)
      else
        System.delete_env("EXUNIT_JSON_OUTPUT_FILE")
      end
    end
  end

  describe "TestFormatter event collection" do
    setup do
      {:ok, config} = ClientUtils.TestFormatter.init([])
      # Stop the cli_formatter to avoid interference
      GenServer.stop(config.cli_formatter)
      # Create a dummy pid for testing
      {:ok, dummy_pid} = Agent.start_link(fn -> [] end)
      config = %{config | cli_formatter: dummy_pid}
      {:ok, config: config}
    end

    test "collects test events", %{config: config} do
      test = %ExUnit.Test{
        case: TestModule,
        name: :"should test",
        state: nil,
        tags: %{file: "/test/file.exs", test_type: :test}
      }

      event = {:test_finished, test}
      {:noreply, new_config} = ClientUtils.TestFormatter.handle_cast(event, config)

      assert length(new_config.events) == 1
      assert hd(new_config.events) == event
    end

    test "increments pass_counter for passing tests", %{config: config} do
      test = %ExUnit.Test{case: TestModule, name: :"should test", state: nil, tags: %{test_type: :test}}
      event = {:test_finished, test}

      {:noreply, new_config} = ClientUtils.TestFormatter.handle_cast(event, config)

      assert new_config.pass_counter == 1
      assert length(new_config.tests) == 1
    end

    test "increments failure_counter for failing tests", %{config: config} do
      failures = [{:error, catch_error(raise "oops"), []}]

      test = %ExUnit.Test{
        case: TestModule,
        name: :"should test",
        tags: %{file: __ENV__.file, line: 1, test_type: :test},
        state: {:failed, failures}
      }

      event = {:test_finished, test}
      {:noreply, new_config} = ClientUtils.TestFormatter.handle_cast(event, config)

      assert new_config.failure_counter == 1
      assert length(new_config.failures) == 1
    end

    test "increments skipped_counter for skipped tests", %{config: config} do
      test = %ExUnit.Test{
        case: TestModule,
        name: :"should test",
        state: {:skip, "skipped"},
        tags: %{test_type: :test}
      }

      event = {:test_finished, test}
      {:noreply, new_config} = ClientUtils.TestFormatter.handle_cast(event, config)

      assert new_config.skipped_counter == 1
      assert length(new_config.pending) == 1
    end

    test "increments skipped_counter for excluded tests", %{config: config} do
      test = %ExUnit.Test{
        case: TestModule,
        name: :"should test",
        state: {:excluded, "excluded"},
        tags: %{test_type: :test}
      }

      event = {:test_finished, test}
      {:noreply, new_config} = ClientUtils.TestFormatter.handle_cast(event, config)

      assert new_config.skipped_counter == 1
      assert length(new_config.pending) == 1
    end

    test "increments invalid_counter for invalid tests", %{config: config} do
      test = %ExUnit.Test{
        case: TestModule,
        name: :"should test",
        state: {:invalid, :some_reason},
        tags: %{test_type: :test}
      }

      event = {:test_finished, test}
      {:noreply, new_config} = ClientUtils.TestFormatter.handle_cast(event, config)

      assert new_config.invalid_counter == 1
    end
  end

  describe "TestFormatter JSON file output" do
    test "writes JSON to file when output_file is set" do
      output_file = Path.join(System.tmp_dir!(), "test_output_#{:rand.uniform(100_000)}.json")

      {:ok, config} = ClientUtils.TestFormatter.init(output_file: output_file)

      # Add a passing test
      test = %ExUnit.Test{case: TestModule, name: :"should test", state: nil, tags: %{test_type: :test}}
      {:noreply, config} = ClientUtils.TestFormatter.handle_cast({:test_finished, test}, config)

      # Set start time
      config = %{config | start_time: NaiveDateTime.utc_now()}

      # Finish the suite
      {:noreply, _config} =
        ClientUtils.TestFormatter.handle_cast({:suite_finished, 1000, 500}, config)

      # Verify file was written
      assert File.exists?(output_file)
      content = File.read!(output_file)
      json = Jason.decode!(content)

      assert json["stats"]["passes"] == 1
      assert length(json["tests"]) == 1

      # Cleanup
      File.rm(output_file)
    end

    test "does not write JSON when output_file is not set" do
      {:ok, config} = ClientUtils.TestFormatter.init([])
      assert config.output_file == nil

      # This should not crash even without output_file
      config = %{config | start_time: NaiveDateTime.utc_now()}

      {:noreply, _config} =
        ClientUtils.TestFormatter.handle_cast({:suite_finished, 1000, 500}, config)
    end
  end

  describe "TestFormatter caching" do
    test "stores events to cache on suite_finished" do
      {:ok, config} = ClientUtils.TestFormatter.init([])

      file = "/test/cached_file.exs"
      before_time = DateTime.utc_now()
      Process.sleep(10)

      test = %ExUnit.Test{
        case: TestModule,
        name: :"should test",
        state: nil,
        tags: %{file: file, test_type: :test}
      }

      {:noreply, config} =
        ClientUtils.TestFormatter.handle_cast({:test_finished, test}, config)

      # Set start time
      config = %{config | start_time: NaiveDateTime.utc_now()}

      # Finish the suite - this should flush events to cache
      {:noreply, new_config} =
        ClientUtils.TestFormatter.handle_cast({:suite_finished, 1000, 500}, config)

      # Events should be cleared after flush
      assert new_config.events == []

      # But they should be in the cache
      assert TestCache.file_tested_after?(file, before_time) == true
    end
  end
end
