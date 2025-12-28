defmodule ExUnitJsonFormatterTest do
  use ExUnit.Case
  import ExUnitJsonFormatter

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
                 "file" => "test/exunit_json_formatter_test.exs",
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
               "error" => %{"file" => "test/exunit_json_formatter_test.exs", "message" => message}
             }
  end

  test "handles excluded test" do
    test = %ExUnit.Test{
      case: TestModule,
      name: :"should test",
      state: {:excluded, "due to integration filter"}
    }

    initial_state = %{skipped_counter: 0, pending: []}
    {:noreply, new_state} = ExUnitJsonFormatter.handle_cast({:test_finished, test}, initial_state)
    assert new_state.skipped_counter == 1
    assert length(new_state.pending) == 1
  end

  test "streaming mode emits suite:start event" do
    import ExUnit.CaptureIO

    state = %{streaming: true, start_time: nil}

    output =
      capture_io(fn ->
        ExUnitJsonFormatter.handle_cast({:suite_started, %{}}, state)
      end)

    assert output =~ ~s("type":"suite:start")
    assert output =~ ~s("start":")
  end

  test "streaming mode emits test:pass event" do
    import ExUnit.CaptureIO

    test = %ExUnit.Test{case: TestModule, name: :"should test", state: nil}
    state = %{streaming: true, pass_counter: 0, tests: []}

    output =
      capture_io(fn ->
        ExUnitJsonFormatter.handle_cast({:test_finished, test}, state)
      end)

    assert output =~ ~s("type":"test:pass")
    assert output =~ ~s("title":"should test")
  end

  test "streaming mode emits test:fail event" do
    import ExUnit.CaptureIO

    failures = [{:error, catch_error(raise "oops"), []}]

    test = %ExUnit.Test{
      case: TestModule,
      name: :"should test",
      tags: %{file: __ENV__.file, line: 1},
      state: {:failed, failures}
    }

    state = %{streaming: true, failure_counter: 0, failures: []}

    output =
      capture_io(fn ->
        ExUnitJsonFormatter.handle_cast({:test_finished, test}, state)
      end)

    assert output =~ ~s("type":"test:fail")
    assert output =~ ~s("title":"should test")
  end

  test "streaming mode emits test:pending event for skipped tests" do
    import ExUnit.CaptureIO

    test = %ExUnit.Test{case: TestModule, name: :"should test", state: {:skip, "skipped"}}
    state = %{streaming: true, skipped_counter: 0, pending: []}

    output =
      capture_io(fn ->
        ExUnitJsonFormatter.handle_cast({:test_finished, test}, state)
      end)

    assert output =~ ~s("type":"test:pending")
    assert output =~ ~s("pending":true)
  end

  test "streaming mode emits test:pending event for excluded tests" do
    import ExUnit.CaptureIO

    test = %ExUnit.Test{case: TestModule, name: :"should test", state: {:excluded, "excluded"}}
    state = %{streaming: true, skipped_counter: 0, pending: []}

    output =
      capture_io(fn ->
        ExUnitJsonFormatter.handle_cast({:test_finished, test}, state)
      end)

    assert output =~ ~s("type":"test:pending")
    assert output =~ ~s("pending":true)
  end

  test "streaming mode emits suite:end event" do
    import ExUnit.CaptureIO

    start_time = NaiveDateTime.utc_now()

    state = %{
      streaming: true,
      start_time: start_time,
      pass_counter: 1,
      failure_counter: 0,
      skipped_counter: 0,
      invalid_counter: 0,
      case_counter: 1,
      tests: [],
      failures: [],
      pending: [],
      output_file: nil
    }

    output =
      capture_io(fn ->
        ExUnitJsonFormatter.handle_cast({:suite_finished, 1000, 500}, state)
      end)

    # Should have both the suite:end event and the final JSON blob
    lines = String.split(output, "\n", trim: true)
    assert length(lines) == 2

    # First line should be the suite:end event
    first_line = hd(lines)
    assert first_line =~ ~s("type":"suite:end")
    assert first_line =~ ~s("stats")

    # Second line should be the final JSON blob
    second_line = Enum.at(lines, 1)
    assert second_line =~ ~s("tests":[])
    assert second_line =~ ~s("failures":[])
  end

  test "non-streaming mode does not emit events" do
    import ExUnit.CaptureIO

    test = %ExUnit.Test{case: TestModule, name: :"should test", state: nil}
    state = %{streaming: false, pass_counter: 0, tests: []}

    output =
      capture_io(fn ->
        ExUnitJsonFormatter.handle_cast({:test_finished, test}, state)
      end)

    assert output == ""
  end

  test "streaming mode can be enabled via environment variable" do
    # Save original value
    original_value = System.get_env("EXUNIT_JSON_STREAMING")

    # Set environment variable
    System.put_env("EXUNIT_JSON_STREAMING", "true")

    {:ok, config} = ExUnitJsonFormatter.init([])
    assert config.streaming == true

    # Restore original value
    if original_value do
      System.put_env("EXUNIT_JSON_STREAMING", original_value)
    else
      System.delete_env("EXUNIT_JSON_STREAMING")
    end
  end

  test "streaming mode defaults to false when environment variable is not set" do
    # Save original value
    original_value = System.get_env("EXUNIT_JSON_STREAMING")

    # Remove environment variable
    System.delete_env("EXUNIT_JSON_STREAMING")

    {:ok, config} = ExUnitJsonFormatter.init([])
    assert config.streaming == false

    # Restore original value
    if original_value do
      System.put_env("EXUNIT_JSON_STREAMING", original_value)
    end
  end
end
