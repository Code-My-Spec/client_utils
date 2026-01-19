defmodule ClientUtils.TestFormatter do
  use GenServer

  @moduledoc """
  ExUnit formatter that:
  - Delegates to CLIFormatter for normal terminal output
  - Writes JSON results to a file (if configured)
  - Caches test events to DETS for later querying
  """

  alias ClientUtils.TestFormatter.JsonFormatter
  alias ClientUtils.TestFormatter.TestCache

  # GenServer callbacks that receive test runner messages

  def init(opts) do
    output_file = opts[:output_file] || System.get_env("EXUNIT_JSON_OUTPUT_FILE")

    # Setup cache
    TestCache.setup()

    # Start CLIFormatter for normal terminal output
    # CLIFormatter expects specific config keys with defaults
    cli_opts =
      opts
      |> Keyword.take([:seed, :trace, :colors, :width, :slowest, :slowest_modules, :max_failures])
      |> Keyword.put_new(:colors, [])
      |> Keyword.put_new(:slowest, 0)
      |> Keyword.put_new(:slowest_modules, 0)

    {:ok, cli_formatter} = GenServer.start_link(ExUnit.CLIFormatter, cli_opts)

    config = %{
      seed: opts[:seed],
      trace: opts[:trace],
      output_file: output_file,
      cli_formatter: cli_formatter,
      pass_counter: 0,
      failure_counter: 0,
      skipped_counter: 0,
      invalid_counter: 0,
      case_counter: 0,
      start_time: nil,
      tests: [],
      failures: [],
      pending: [],
      events: []
    }

    {:ok, config}
  end

  def handle_cast({:suite_started, _opts} = event, state) do
    start_time = NaiveDateTime.utc_now()

    # Forward to CLI formatter
    GenServer.cast(state.cli_formatter, event)

    {:noreply, %{state | start_time: start_time}}
  end

  def handle_cast({:suite_finished, run_us, load_us} = event, state) do
    # Flush cached events
    TestCache.store_events(state.events)

    # Write JSON to file if configured
    if state.output_file do
      stats = JsonFormatter.format_stats(state, run_us, load_us)

      stats
      |> JsonFormatter.format_suite_result(state.tests, state.failures, state.pending)
      |> Jason.encode!()
      |> write_to_file(state.output_file)
    end

    # Forward to CLI formatter
    GenServer.cast(state.cli_formatter, event)

    {:noreply, %{state | events: []}}
  end

  def handle_cast({:suite_finished, %{run: run_us, load: load_us}} = event, state) do
    # Flush cached events
    TestCache.store_events(state.events)

    # Write JSON to file if configured
    if state.output_file do
      stats = JsonFormatter.format_stats(state, run_us, load_us)

      stats
      |> JsonFormatter.format_suite_result(state.tests, state.failures, state.pending)
      |> Jason.encode!()
      |> write_to_file(state.output_file)
    end

    # Forward to CLI formatter
    GenServer.cast(state.cli_formatter, event)

    {:noreply, %{state | events: []}}
  end

  def handle_cast({:case_started, _} = event, state) do
    GenServer.cast(state.cli_formatter, event)
    {:noreply, collect_event(state, event)}
  end

  def handle_cast({:module_started, _} = event, state) do
    GenServer.cast(state.cli_formatter, event)
    {:noreply, collect_event(state, event)}
  end

  def handle_cast({:module_finished, _} = event, state) do
    GenServer.cast(state.cli_formatter, event)
    {:noreply, collect_event(state, event)}
  end

  def handle_cast(
        {:case_finished, test_case = %ExUnit.TestCase{state: {:failed, failure}}} = event,
        state
      ) do
    test_result = JsonFormatter.format_test_case_failure(test_case, failure)
    GenServer.cast(state.cli_formatter, event)

    state = collect_event(state, event)
    {:noreply, %{state | failures: [test_result | state.failures]}}
  end

  def handle_cast({:case_finished, _} = event, state) do
    GenServer.cast(state.cli_formatter, event)
    state = collect_event(state, event)
    {:noreply, %{state | case_counter: state.case_counter + 1}}
  end

  def handle_cast({:test_started, _} = event, state) do
    GenServer.cast(state.cli_formatter, event)
    {:noreply, collect_event(state, event)}
  end

  def handle_cast({:test_finished, test = %ExUnit.Test{state: nil}} = event, state) do
    test_result = JsonFormatter.format_test_pass(test)
    GenServer.cast(state.cli_formatter, event)

    state = collect_event(state, event)

    {:noreply,
     %{state | pass_counter: state.pass_counter + 1, tests: [test_result | state.tests]}}
  end

  def handle_cast({:test_finished, test = %ExUnit.Test{state: {:failed, failure}}} = event, state) do
    test_result = JsonFormatter.format_test_failure(test, failure)
    GenServer.cast(state.cli_formatter, event)

    state = collect_event(state, event)

    {:noreply,
     %{
       state
       | failure_counter: state.failure_counter + 1,
         failures: [test_result | state.failures]
     }}
  end

  def handle_cast({:test_finished, test = %ExUnit.Test{state: {:skip, _}}} = event, state) do
    test_result = JsonFormatter.format_test_pending(test)
    GenServer.cast(state.cli_formatter, event)

    state = collect_event(state, event)

    {:noreply,
     %{
       state
       | skipped_counter: state.skipped_counter + 1,
         pending: [test_result | state.pending]
     }}
  end

  def handle_cast({:test_finished, %ExUnit.Test{state: {:invalid, _}}} = event, state) do
    GenServer.cast(state.cli_formatter, event)
    state = collect_event(state, event)
    {:noreply, %{state | invalid_counter: state.invalid_counter + 1}}
  end

  def handle_cast({:test_finished, test = %ExUnit.Test{state: {:excluded, _}}} = event, state) do
    test_result = JsonFormatter.format_test_pending(test)
    GenServer.cast(state.cli_formatter, event)

    state = collect_event(state, event)

    {:noreply,
     %{
       state
       | skipped_counter: state.skipped_counter + 1,
         pending: [test_result | state.pending]
     }}
  end

  # Catch-all for any other events
  def handle_cast(event, state) do
    GenServer.cast(state.cli_formatter, event)
    {:noreply, collect_event(state, event)}
  end

  # Private functions

  defp collect_event(state, event) do
    %{state | events: state.events ++ [event]}
  end

  defp write_to_file(json, output_file) do
    File.write!(output_file, json)
  end
end
