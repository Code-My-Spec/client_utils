defmodule ClientUtils.CredoReporter do
  @moduledoc """
  A Credo plugin that reports each finding to the CodeMySpec harness that
  started the run, as Credo finds it, and a `finished` event with the totals
  (`ClientUtils.RunLink`).

  The harness turns it on for its own runs through `CREDO_EXTRA_CONFIG`, so a
  project's `.credo.exs` names nothing. Started without a harness, it adds
  nothing to the run.

  Credo collects findings as each check finishes and filters them only at
  the end, so they are read from its collection while the checks run and
  passed through the same filters Credo applies before printing.
  """

  alias ClientUtils.RunLink

  @compile {:no_warn_undefined,
            [
              Credo.Plugin,
              Credo.Execution,
              Credo.CLI.Filter,
              Credo.CLI.Command.Suggest.SuggestCommand
            ]}

  @pipeline Credo.CLI.Command.Suggest.SuggestCommand
  @poll_ms 200

  @doc false
  def init(exec) do
    case RunLink.join() do
      nil ->
        exec

      link ->
        exec
        |> Credo.Execution.put_assign(:client_utils_run_link, link)
        |> Credo.Plugin.prepend_task(@pipeline, :run_analysis, __MODULE__.Start)
        |> Credo.Plugin.append_task(@pipeline, :filter_issues, __MODULE__.Finish)
    end
  end

  defmodule Start do
    @moduledoc false
    @compile {:no_warn_undefined, Credo.Execution}

    alias ClientUtils.CredoReporter

    def call(exec, _opts) do
      link = Credo.Execution.get_assign(exec, :client_utils_run_link)
      watcher = spawn_link(fn -> CredoReporter.watch(exec, link, MapSet.new()) end)
      Credo.Execution.put_assign(exec, :client_utils_credo_watcher, watcher)
    end

    def error(exec, _opts), do: exec
  end

  defmodule Finish do
    @moduledoc false
    @compile {:no_warn_undefined, Credo.Execution}

    alias ClientUtils.CredoReporter

    def call(exec, _opts) do
      CredoReporter.finish(exec)
      exec
    end

    def error(exec, _opts), do: exec
  end

  @doc false
  def watch(exec, link, sent) do
    receive do
      {:stop, from} -> send(from, {:sent, report_new(link, sent, relevant(exec))})
    after
      @poll_ms -> watch(exec, link, report_new(link, sent, relevant(exec)))
    end
  end

  @doc false
  def finish(exec) do
    link = Credo.Execution.get_assign(exec, :client_utils_run_link)
    watcher = Credo.Execution.get_assign(exec, :client_utils_credo_watcher)
    send(watcher, {:stop, self()})
    sent = receive do: ({:sent, sent} -> sent)

    # Set by Credo's own filtering by now: exactly what it reports.
    issues = Credo.Execution.get_issues(exec)
    report_new(link, sent, issues)

    RunLink.report(link, %{
      "event" => "finished",
      "files" => length(Credo.Execution.get_source_files(exec)),
      "findings" => length(issues)
    })
  end

  defp relevant(exec) do
    exec
    |> Credo.Execution.get_issues()
    |> Credo.CLI.Filter.important(exec)
    |> Credo.CLI.Filter.valid_issues(exec)
  end

  defp report_new(link, sent, issues) do
    Enum.reduce(issues, sent, fn issue, sent ->
      key = {issue.check, issue.filename, issue.line_no, issue.column, issue.message}

      if MapSet.member?(sent, key) do
        sent
      else
        RunLink.report(link, finding(issue))
        MapSet.put(sent, key)
      end
    end)
  end

  defp finding(issue) do
    %{
      "event" => "finding",
      "check" => inspect(issue.check),
      "category" => to_string(issue.category),
      "priority" => issue.priority,
      "file" => issue.filename,
      "line" => issue.line_no,
      "column" => issue.column,
      "message" => issue.message
    }
  end
end
