# ExUnit formatter for the evidence writer: a SARIF result for every test run.
#
#   elixir deps/client_utils/priv/evidence.exs run exunit -- \
#     mix test --formatter ClientUtils.Evidence.Formatter --formatter ExUnit.CLIFormatter
#
# The CLI formatter beside it keeps the console output. When the suite finishes
# this writes a SARIF 2.1.0 file to $EVIDENCE_EXUNIT_SARIF (the writer sets it,
# and folds these results into the one file it writes; unset, nothing is
# written). One result per test that ran:
#
#   kind "pass", level "none"   a passing test
#   kind "fail", level "error"  a failing test, or one its module's setup_all
#                               failed, with the failure as its message and the
#                               test's file and line as its location
#
# ruleId is the test's module and name, "MathTest test adds numbers". Skipped
# and excluded tests did not run and are not results.
#
# It uses nothing but Elixir and OTP (JSON through OTP's :json or the small
# encoder below), so `elixir -r` can also load it in a project without client_utils.

defmodule ClientUtils.Evidence.Formatter do
  @moduledoc false
  use GenServer

  @impl true
  def init(_opts), do: {:ok, []}

  @impl true
  def handle_cast({:test_finished, test}, tests), do: {:noreply, [test | tests]}

  def handle_cast({:suite_finished, _times}, tests) do
    case System.get_env("EVIDENCE_EXUNIT_SARIF") do
      blank when blank in [nil, ""] -> :ok
      path -> write!(path, tests |> Enum.reverse() |> Enum.flat_map(&result/1))
    end

    {:noreply, tests}
  end

  def handle_cast(_event, tests), do: {:noreply, tests}

  defp write!(path, results) do
    sarif = %{
      "$schema" => "https://json.schemastore.org/sarif-2.1.0.json",
      "version" => "2.1.0",
      "runs" => [
        %{
          "tool" => %{"driver" => %{"name" => "exunit", "version" => System.version()}},
          "results" => results
        }
      ]
    }

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, encode(sarif))
  end

  defp result(%{state: nil} = test),
    do: [%{"kind" => "pass", "level" => "none", "ruleId" => rule(test)}]

  defp result(%{state: {:failed, failures}} = test),
    do: [fail(test, ExUnit.Formatter.format_test_failure(test, failures, 1, :infinity, &plain/2))]

  defp result(%{state: {:invalid, module}} = test) do
    failures =
      case module do
        %{state: {:failed, failures}} -> failures
        _ -> []
      end

    [
      fail(
        test,
        ExUnit.Formatter.format_test_all_failure(module, failures, 1, :infinity, &plain/2)
      )
    ]
  end

  # Skipped, excluded: never ran.
  defp result(_test), do: []

  defp fail(test, text) do
    %{
      "kind" => "fail",
      "level" => "error",
      "ruleId" => rule(test),
      "message" => %{"text" => String.slice(String.trim(text), 0, 4000)},
      "locations" => [
        %{
          "physicalLocation" => %{
            "artifactLocation" => %{"uri" => Path.relative_to(test.tags.file, File.cwd!())},
            "region" => %{"startLine" => test.tags.line}
          }
        }
      ]
    }
  end

  defp rule(test), do: "#{inspect(test.module)} #{test.name}"

  defp plain(:diff_enabled?, _), do: false
  defp plain(_key, text), do: text

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
