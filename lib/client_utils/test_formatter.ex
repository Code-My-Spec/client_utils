defmodule ClientUtils.TestFormatter do
  use GenServer

  @moduledoc """
  ExUnit formatter that:
  - Delegates to CLIFormatter for normal terminal output
  - Writes JSON results to a file (if configured)
  - Reports each event, as it happens, to the CodeMySpec harness that
    started the run (`ClientUtils.RunLink`)
  """

  require Logger

  alias ClientUtils.RunLink
  alias ClientUtils.TestFormatter.JsonFormatter

  # GenServer callbacks that receive test runner messages

  def handle_cast(event, state) do
    RunLink.report(state.link, event |> live_event() |> of_shard(state.shard?))
    handle_event(event, state)
  end

  def init(opts) do
    output_file = opts[:output_file] || System.get_env("EXUNIT_JSON_OUTPUT_FILE")
    remove_legacy_queue_files()

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
      # One of a run's `CMS_RUN_SHARDS` processes: the run finishes once, when
      # its runner exits, not when this shard does.
      shard?: System.get_env("CMS_RUN_SHARDS") not in [nil, ""],
      link: RunLink.join(),
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
      pending: []
    }

    {:ok, config}
  end

  defp handle_event({:suite_started, _opts} = event, state) do
    start_time = NaiveDateTime.utc_now()
    GenServer.cast(state.cli_formatter, event)
    {:noreply, %{state | start_time: start_time}}
  end

  defp handle_event({:suite_finished, run_us, load_us} = event, state) do
    flush_results(state, run_us, load_us)
    GenServer.cast(state.cli_formatter, event)
    {:noreply, state}
  end

  defp handle_event({:suite_finished, %{run: run_us, load: load_us}} = event, state) do
    flush_results(state, run_us, load_us)
    GenServer.cast(state.cli_formatter, event)
    {:noreply, state}
  end

  defp handle_event(
         {:case_finished, test_case = %ExUnit.TestCase{state: {:failed, failure}}} = event,
         state
       ) do
    test_result = JsonFormatter.format_test_case_failure(test_case, failure)
    GenServer.cast(state.cli_formatter, event)

    {:noreply, %{state | failures: [test_result | state.failures]}}
  end

  defp handle_event({:case_finished, _} = event, state) do
    GenServer.cast(state.cli_formatter, event)
    {:noreply, %{state | case_counter: state.case_counter + 1}}
  end

  defp handle_event({:test_started, _} = event, state) do
    GenServer.cast(state.cli_formatter, event)
    {:noreply, state}
  end

  defp handle_event({:test_finished, test = %ExUnit.Test{state: nil}} = event, state) do
    test_result = JsonFormatter.format_test_pass(test)
    GenServer.cast(state.cli_formatter, event)

    {:noreply,
     %{state | pass_counter: state.pass_counter + 1, tests: [test_result | state.tests]}}
  end

  defp handle_event(
         {:test_finished, test = %ExUnit.Test{state: {:failed, failure}}} = event,
         state
       ) do
    test_result = JsonFormatter.format_test_failure(test, failure)
    GenServer.cast(state.cli_formatter, event)

    {:noreply,
     %{
       state
       | failure_counter: state.failure_counter + 1,
         failures: [test_result | state.failures]
     }}
  end

  defp handle_event({:test_finished, test = %ExUnit.Test{state: {:skip, _}}} = event, state) do
    test_result = JsonFormatter.format_test_pending(test)
    GenServer.cast(state.cli_formatter, event)

    {:noreply,
     %{
       state
       | skipped_counter: state.skipped_counter + 1,
         pending: [test_result | state.pending]
     }}
  end

  defp handle_event({:test_finished, %ExUnit.Test{state: {:invalid, _}}} = event, state) do
    GenServer.cast(state.cli_formatter, event)
    {:noreply, %{state | invalid_counter: state.invalid_counter + 1}}
  end

  defp handle_event({:test_finished, test = %ExUnit.Test{state: {:excluded, _}}} = event, state) do
    test_result = JsonFormatter.format_test_pending(test)
    GenServer.cast(state.cli_formatter, event)

    {:noreply,
     %{
       state
       | skipped_counter: state.skipped_counter + 1,
         pending: [test_result | state.pending]
     }}
  end

  # Catch-all for any other events
  defp handle_event(event, state) do
    GenServer.cast(state.cli_formatter, event)
    {:noreply, state}
  end

  # Private functions

  # What the harness is told of each event, as plain data: the run's node and
  # the harness's need not share ExUnit's structs.
  defp live_event({:module_started, %ExUnit.TestModule{file: file}}),
    do: %{"event" => "file_started", "file" => relative(file)}

  defp live_event({:module_finished, %ExUnit.TestModule{file: file}}),
    do: %{"event" => "file_finished", "file" => relative(file)}

  defp live_event({:test_finished, %ExUnit.Test{} = test}) do
    file = relative(test.tags[:file])

    Map.merge(
      %{
        "event" => "test",
        "name" => test_name(test),
        "module" => inspect(test.module),
        "file" => file,
        "line" => test.tags[:line]
      },
      outcome(test.state, file, test.tags[:line])
    )
  end

  defp live_event({:suite_finished, _times}), do: %{"event" => "finished"}
  defp live_event({:suite_finished, _run_us, _load_us}), do: %{"event" => "finished"}
  defp live_event(_event), do: nil

  defp of_shard(%{"event" => "finished"}, true), do: nil
  defp of_shard(event, _shard?), do: event

  defp outcome(nil, _file, _line), do: %{"state" => "passed"}

  defp outcome({:failed, [{_kind, reason, stack} | _]}, file, line),
    do: %{
      "state" => "failed",
      "message" => message(reason),
      "failure_line" => failure_line(stack, file, line)
    }

  defp outcome({:skipped, _}, _file, _line), do: %{"state" => "skipped"}
  defp outcome({:excluded, _}, _file, _line), do: %{"state" => "skipped"}
  defp outcome({state, _}, _file, _line), do: %{"state" => to_string(state)}

  defp message(%ExUnit.AssertionError{message: message}), do: message
  defp message(exception) when is_exception(exception), do: Exception.message(exception)
  defp message(other), do: inspect(other)

  # The line in the test's own file the failure happened at, else the test's.
  defp failure_line(stack, file, line) do
    Enum.find_value(stack, line, fn
      {_m, _f, _a, location} ->
        if relative(to_string(location[:file])) == file, do: location[:line]

      _frame ->
        nil
    end)
  end

  defp test_name(%ExUnit.Test{name: name}),
    do: name |> Atom.to_string() |> String.replace_prefix("test ", "")

  defp relative(nil), do: nil
  defp relative(file), do: Path.relative_to(file, File.cwd!())

  # What 0.1's `mix agent_test` and its event cache left in a project. Runs are
  # queued by CodeMySpec now, so a project upgraded from 0.1 drops them.
  @legacy_queue_files [
    ".code_my_spec/internal/agent_test_events.json",
    ".code_my_spec/internal/agent_test.lock.json",
    ".code_my_spec/internal/agent_test.log",
    ".code_my_spec/internal/callers"
  ]

  defp remove_legacy_queue_files, do: Enum.each(@legacy_queue_files, &File.rm_rf/1)

  defp flush_results(state, run_us, load_us) do
    # The file write is best-effort — never crash the formatter
    if state.output_file do
      try do
        stats = JsonFormatter.format_stats(state, run_us, load_us)

        stats
        |> JsonFormatter.format_suite_result(state.tests, state.failures, state.pending)
        |> Jason.encode!()
        |> write_to_file(state.output_file)
      rescue
        e -> Logger.warning("JSON output write failed: #{Exception.message(e)}")
      end
    end
  end

  defp write_to_file(json, output_file) do
    output_file |> Path.dirname() |> File.mkdir_p!()
    File.write!(output_file, json)
  end
end
