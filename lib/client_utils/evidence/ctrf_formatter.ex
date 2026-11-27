# ExUnit formatter: a CTRF report (Common Test Report Format 0.3.0, ctrf.io)
# for every test run.
#
#   mix test --formatter ExUnit.CLIFormatter --formatter ClientUtils.Evidence.CTRFFormatter
#
# It runs beside ClientUtils.Evidence.Formatter (the SARIF results) and changes neither them
# nor the run's exit status. When the suite finishes it writes one JSON file,
# .code_my_spec/evidence/<reportId>.ctrf.json under the directory mix runs in:
#
#   results.tool         name "ExUnit", the Elixir version
#   results.summary      tests, passed, failed, skipped, pending, other, start,
#                        stop (ms since the epoch)
#   results.tests[]      one per test: name ("MathTest test adds numbers"),
#                        status, duration (ms), filePath, line, suite (the
#                        module), tags, and message and trace when it failed
#   results.environment  commit (git rev-parse HEAD), branchName, and
#                        extra["codemyspec.tree"], the tree tested: HEAD plus
#                        every uncommitted and untracked (not ignored) file
#
# Every time is integer milliseconds: durations, start and stop.
#
# Status: passed, failed, skipped (@tag :skip), and other for an excluded test
# or an invalid one (its module's setup_all failed, which carries a message).
#
# It uses nothing but Elixir and OTP (JSON through OTP's :json or the small
# encoder below), so `elixir -r` can also load it in a project without client_utils.

defmodule ClientUtils.Evidence.CTRFFormatter do
  @moduledoc false
  use GenServer

  # Tags ExUnit sets on every test: not the test's own classifications.
  @builtin ~w(async file line module test test_type registered describe describe_line
              doctest doctest_line doctest_data test_pid)a

  @impl true
  def init(_opts), do: {:ok, %{start: now(), environment: environment(), tests: []}}

  @impl true
  def handle_cast({:test_finished, test}, state),
    do: {:noreply, %{state | tests: [entry(test) | state.tests]}}

  def handle_cast({:suite_finished, _times}, state) do
    write!(state, now())
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  defp write!(state, stop) do
    tests = Enum.reverse(state.tests)
    count = fn status -> Enum.count(tests, &(&1["status"] == status)) end
    id = uuid()

    report = %{
      "reportFormat" => "CTRF",
      "specVersion" => "0.3.0",
      "reportId" => id,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "generatedBy" => "ClientUtils.Evidence.CTRFFormatter",
      "results" => %{
        "tool" => %{"name" => "ExUnit", "version" => System.version()},
        "summary" => %{
          "tests" => length(tests),
          "passed" => count.("passed"),
          "failed" => count.("failed"),
          "skipped" => count.("skipped"),
          "pending" => 0,
          "other" => count.("other"),
          "start" => state.start,
          "stop" => stop,
          "duration" => stop - state.start
        },
        "tests" => tests,
        "environment" => state.environment
      }
    }

    path = Path.join([File.cwd!(), ".code_my_spec/evidence", id <> ".ctrf.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, encode(report))
  end

  defp entry(test) do
    {status, failure} = outcome(test)

    Map.merge(
      %{
        "name" => "#{inspect(test.module)} #{test.name}",
        "status" => status,
        "duration" => div(test.time, 1000),
        "filePath" => Path.relative_to(test.tags.file, File.cwd!()),
        "line" => test.tags.line,
        "suite" => [inspect(test.module)],
        "tags" => tags(test.tags)
      },
      failure
    )
  end

  defp outcome(%{state: nil}), do: {"passed", %{}}

  defp outcome(%{state: {:failed, failures}} = test) do
    text = ExUnit.Formatter.format_test_failure(test, failures, 1, :infinity, &plain/2)
    {"failed", failure(text, failures)}
  end

  defp outcome(%{state: {:skipped, _}}), do: {"skipped", %{}}

  defp outcome(%{state: {:invalid, module}}) do
    failures =
      case module do
        %{state: {:failed, failures}} -> failures
        _ -> []
      end

    text = ExUnit.Formatter.format_test_all_failure(module, failures, 1, :infinity, &plain/2)
    {"other", failure(text, failures)}
  end

  # Excluded: never ran.
  defp outcome(_test), do: {"other", %{}}

  defp failure(text, failures) do
    trace =
      Enum.map_join(failures, "\n", fn {_kind, _reason, stack} ->
        Exception.format_stacktrace(stack)
      end)

    %{"message" => String.trim(text), "trace" => trace}
  end

  defp tags(tags) do
    for {key, value} <- Enum.sort(tags), key not in @builtin, value not in [nil, false] do
      if value == true, do: Atom.to_string(key), else: "#{key}:#{tag_value(value)}"
    end
  end

  defp tag_value(value) when is_binary(value), do: value
  defp tag_value(value) when is_atom(value) or is_number(value), do: to_string(value)
  defp tag_value(value), do: inspect(value)

  defp plain(:diff_enabled?, _), do: false
  defp plain(_key, text), do: text

  defp now, do: System.os_time(:millisecond)

  ## Environment

  defp environment do
    head = git(["rev-parse", "HEAD"])

    %{
      "commit" => head,
      "branchName" => git(["symbolic-ref", "--short", "-q", "HEAD"]),
      "extra" => if(tree = head && tested_tree(), do: %{"codemyspec.tree" => tree}, else: %{})
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  # The working tree as tested, through a temporary index: the real one is
  # never read into or written.
  defp tested_tree do
    top = git(["rev-parse", "--show-toplevel"])
    index = Path.join(System.tmp_dir!(), "ctrf-index-#{uuid()}")
    opts = [cd: top, env: [{"GIT_INDEX_FILE", index}], stderr_to_stdout: true]

    try do
      with {_, 0} <- System.cmd("git", ["read-tree", "HEAD"], opts),
           {_, 0} <- System.cmd("git", ["add", "-A"], opts),
           {tree, 0} <- System.cmd("git", ["write-tree"], opts) do
        String.trim(tree)
      else
        _ -> nil
      end
    after
      File.rm(index)
      File.rm(index <> ".lock")
    end
  end

  defp git(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    hex = Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)
    <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> = hex
    Enum.join([p1, p2, p3, p4, p5], "-")
  end

  defp encode(term) do
    if Code.ensure_loaded?(:json) and function_exported?(:json, :encode, 1),
      do: IO.iodata_to_binary(:json.encode(term)),
      else: IO.iodata_to_binary(enc(term))
  end

  defp enc(n) when is_integer(n), do: Integer.to_string(n)
  defp enc(s) when is_binary(s), do: [?", esc(s), ?"]
  defp enc(l) when is_list(l), do: [?[, Enum.map_intersperse(l, ?,, &enc/1), ?]]

  defp enc(m) when is_map(m),
    do: [?{, Enum.map_intersperse(m, ?,, fn {k, v} -> [enc(k), ?:, enc(v)] end), ?}]

  defp esc(s) do
    for <<c::utf8 <- s>>, into: "" do
      case c do
        ?" -> "\\\""
        ?\\ -> "\\\\"
        ?\n -> "\\n"
        ?\r -> "\\r"
        ?\t -> "\\t"
        c when c < 0x20 -> "\\u" <> String.pad_leading(Integer.to_string(c, 16), 4, "0")
        c -> <<c::utf8>>
      end
    end
  end
end
