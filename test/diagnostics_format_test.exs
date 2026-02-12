defmodule ClientUtils.DiagnosticsFormatTest do
  use ExUnit.Case

  alias ClientUtils.DiagnosticsFormat
  alias Mix.Task.Compiler.Diagnostic

  defp make_diagnostic(overrides \\ %{}) do
    Map.merge(
      %Diagnostic{
        file: "/app/lib/example.ex",
        source: "/app/lib/example.ex",
        severity: :warning,
        message: "variable \"x\" is unused",
        position: {3, 5},
        compiler_name: "Elixir",
        span: {3, 6},
        details: nil,
        stacktrace: []
      },
      overrides
    )
  end

  describe "to_map/1" do
    test "converts a diagnostic struct to a map" do
      diag = make_diagnostic()
      result = DiagnosticsFormat.to_map(diag)

      assert result.file == "/app/lib/example.ex"
      assert result.source == "/app/lib/example.ex"
      assert result.severity == :warning
      assert result.message == "variable \"x\" is unused"
      assert result.compiler_name == "Elixir"
      assert result.details == nil
    end

    test "formats {line, column} position as map" do
      diag = make_diagnostic(%{position: {10, 3}})
      assert DiagnosticsFormat.to_map(diag).position == %{line: 10, column: 3}
    end

    test "formats integer position as integer" do
      diag = make_diagnostic(%{position: 42})
      assert DiagnosticsFormat.to_map(diag).position == 42
    end

    test "formats nil position as nil" do
      diag = make_diagnostic(%{position: nil})
      assert DiagnosticsFormat.to_map(diag).position == nil
    end

    test "formats {line, column} span as map" do
      diag = make_diagnostic(%{span: {5, 12}})
      assert DiagnosticsFormat.to_map(diag).span == %{line: 5, column: 12}
    end

    test "formats nil span as nil" do
      diag = make_diagnostic(%{span: nil})
      assert DiagnosticsFormat.to_map(diag).span == nil
    end

    test "formats stacktrace with module entries" do
      diag =
        make_diagnostic(%{
          stacktrace: [
            {MyModule, :my_func, 2, [file: ~c"lib/my.ex", line: 10, column: 3]}
          ]
        })

      [entry] = DiagnosticsFormat.to_map(diag).stacktrace
      assert entry.module == MyModule
      assert entry.function == :my_func
      assert entry.arity == 2
      assert entry.file == ~c"lib/my.ex"
      assert entry.line == 10
      assert entry.column == 3
    end

    test "formats stacktrace with anonymous function entries" do
      diag =
        make_diagnostic(%{
          stacktrace: [
            {fn -> :ok end, 0, [file: ~c"lib/my.ex", line: 5]}
          ]
        })

      [entry] = DiagnosticsFormat.to_map(diag).stacktrace
      assert entry.function == "(anonymous)"
      assert entry.arity == 0
    end

    test "formats stacktrace with list arity as length" do
      diag =
        make_diagnostic(%{
          stacktrace: [
            {MyModule, :my_func, [:a, :b, :c], [file: ~c"lib/my.ex", line: 1]}
          ]
        })

      [entry] = DiagnosticsFormat.to_map(diag).stacktrace
      assert entry.arity == 3
    end

    test "formats nil stacktrace as nil" do
      diag = make_diagnostic(%{stacktrace: nil})
      assert DiagnosticsFormat.to_map(diag).stacktrace == nil
    end

    test "formats empty stacktrace as empty list" do
      diag = make_diagnostic(%{stacktrace: []})
      assert DiagnosticsFormat.to_map(diag).stacktrace == []
    end
  end

  describe "to_jsonl/1" do
    test "returns empty iodata for empty list" do
      assert IO.iodata_to_binary(DiagnosticsFormat.to_jsonl([])) == ""
    end

    test "returns single JSON line for one diagnostic" do
      diag = make_diagnostic()
      result = IO.iodata_to_binary(DiagnosticsFormat.to_jsonl([diag]))

      assert {:ok, decoded} = Jason.decode(result)
      assert decoded["severity"] == "warning"
      assert decoded["message"] == "variable \"x\" is unused"
      refute String.contains?(result, "\n")
    end

    test "returns newline-separated JSON lines for multiple diagnostics" do
      diag1 = make_diagnostic(%{message: "first warning"})
      diag2 = make_diagnostic(%{message: "second warning", severity: :error})

      result = IO.iodata_to_binary(DiagnosticsFormat.to_jsonl([diag1, diag2]))
      lines = String.split(result, "\n")

      assert length(lines) == 2

      assert {:ok, line1} = Jason.decode(Enum.at(lines, 0))
      assert line1["message"] == "first warning"

      assert {:ok, line2} = Jason.decode(Enum.at(lines, 1))
      assert line2["message"] == "second warning"
      assert line2["severity"] == "error"
    end
  end
end
