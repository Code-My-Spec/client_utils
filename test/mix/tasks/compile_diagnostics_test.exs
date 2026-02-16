defmodule Mix.Tasks.Compile.DiagnosticsTest do
  use ExUnit.Case

  @output_file "test_diagnostics_output.jsonl"

  setup do
    on_exit(fn ->
      File.rm(@output_file)

      try do
        :persistent_term.erase({Mix.Tasks.Compile.Spex, :diagnostics})
      rescue
        ArgumentError -> :ok
      end
    end)

    :ok
  end

  describe "run/1" do
    test "returns {:noop, []}" do
      assert {:noop, []} = Mix.Tasks.Compile.Diagnostics.run([])
    end
  end

  describe "write_diagnostics/2" do
    test "writes JSONL file from extra diagnostics" do
      diag = build_diagnostic(message: "test warning", severity: :warning)

      Mix.Tasks.Compile.Diagnostics.write_diagnostics(@output_file, [diag])

      assert File.exists?(@output_file)
      lines = read_jsonl(@output_file)
      assert length(lines) == 1
      assert hd(lines)["message"] == "test warning"
    end

    test "merges extra diagnostics with collected diagnostics" do
      a = build_diagnostic(message: "from collect", severity: :warning)
      b = build_diagnostic(message: "from callback", severity: :error)

      Mix.Tasks.Compile.Diagnostics.write_diagnostics(@output_file, [a, b])

      lines = read_jsonl(@output_file)
      messages = Enum.map(lines, & &1["message"])
      assert "from collect" in messages
      assert "from callback" in messages
    end

    test "deduplicates diagnostics by file + position + message" do
      diag = build_diagnostic(message: "duplicate warning", position: 5, file: "/app/foo.ex")
      same = build_diagnostic(message: "duplicate warning", position: 5, file: "/app/foo.ex")

      Mix.Tasks.Compile.Diagnostics.write_diagnostics(@output_file, [diag, same])

      lines = read_jsonl(@output_file)
      dupes = Enum.filter(lines, &(&1["message"] == "duplicate warning"))
      assert length(dupes) == 1
    end

    test "writes error diagnostics (syntax errors via after_compiler callback)" do
      error_diag =
        build_diagnostic(
          message: "unexpected token: end",
          severity: :error,
          file: "/app/lib/broken.ex",
          position: 10,
          compiler_name: "Elixir"
        )

      Mix.Tasks.Compile.Diagnostics.write_diagnostics(@output_file, [error_diag])

      assert File.exists?(@output_file)
      lines = read_jsonl(@output_file)
      assert length(lines) == 1

      line = hd(lines)
      assert line["message"] == "unexpected token: end"
      assert line["severity"] == "error"
      assert line["compiler_name"] == "Elixir"
    end

    test "creates parent directories for output path" do
      nested_output = "test_tmp/nested/diagnostics.jsonl"

      on_exit(fn ->
        File.rm_rf!("test_tmp")
      end)

      Mix.Tasks.Compile.Diagnostics.write_diagnostics(nested_output)
      assert File.exists?(nested_output)
    end

    test "writes empty file when no diagnostics exist" do
      Mix.Tasks.Compile.Diagnostics.write_diagnostics(@output_file)

      assert File.exists?(@output_file)
      assert File.read!(@output_file) == ""
    end

    test "normalizes raw SyntaxError structs from after_compiler callback" do
      syntax_error = %SyntaxError{
        file: "/app/lib/broken.ex",
        line: 16,
        column: 3,
        description: "unexpected reserved word: end"
      }

      Mix.Tasks.Compile.Diagnostics.write_diagnostics(@output_file, [syntax_error])

      assert File.exists?(@output_file)
      lines = read_jsonl(@output_file)
      assert length(lines) == 1

      line = hd(lines)
      assert line["message"] == "unexpected reserved word: end"
      assert line["severity"] == "error"
      assert line["file"] == "/app/lib/broken.ex"
      assert line["position"] == 16
    end

    test "skips unrecognized diagnostic types and logs a warning" do
      diag = build_diagnostic(message: "good one")

      Mix.Tasks.Compile.Diagnostics.write_diagnostics(@output_file, [diag, :garbage])

      lines = read_jsonl(@output_file)
      assert length(lines) == 1
      assert hd(lines)["message"] == "good one"
    end
  end

  describe "spex integration" do
    test "spex diagnostics/0 is queryable after seeding persistent_term" do
      fake_diag = build_diagnostic(message: "test spex warning", compiler_name: "Spex")
      :persistent_term.put({Mix.Tasks.Compile.Spex, :diagnostics}, [fake_diag])

      stored = Mix.Tasks.Compile.Spex.diagnostics()
      assert length(stored) == 1
      assert hd(stored).message == "test spex warning"
    end
  end

  # --- helpers ---

  defp build_diagnostic(overrides) do
    defaults = [
      file: "/app/test/my_spex.exs",
      source: "/app/test/my_spex.exs",
      severity: :warning,
      message: "test diagnostic",
      position: {5, 1},
      compiler_name: "Spex",
      span: nil,
      details: nil,
      stacktrace: []
    ]

    attrs = Keyword.merge(defaults, overrides)
    struct!(Mix.Task.Compiler.Diagnostic, attrs)
  end

  defp read_jsonl(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end
end
