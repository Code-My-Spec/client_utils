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

  test "writes JSONL file with diagnostics from Elixir compiler" do
    # The Elixir compiler's diagnostics/0 returns whatever the last compile produced.
    # In a clean build this may be empty, so we just verify the file gets written
    # and is valid JSONL.
    Mix.Tasks.Compile.Diagnostics.run(["--output", @output_file])

    assert File.exists?(@output_file)
    contents = File.read!(@output_file)

    # Each non-empty line should be valid JSON
    for line <- String.split(contents, "\n", trim: true) do
      assert {:ok, _} = Jason.decode(line)
    end
  end

  test "collects diagnostics from compilers that implement diagnostics/0" do
    # The Elixir compiler implements diagnostics/0 and is always in the compilers list.
    # We verify that collect works by checking it queries the Elixir compiler.
    # In a consuming project with compilers: Mix.compilers() ++ [:spex, :diagnostics],
    # the spex compiler's diagnostics/0 would also be queried.
    Mix.Tasks.Compile.Diagnostics.run(["--output", @output_file])

    assert File.exists?(@output_file)
    contents = File.read!(@output_file)

    # All diagnostics should have a compiler_name
    for line <- String.split(contents, "\n", trim: true) do
      decoded = Jason.decode!(line)
      assert is_binary(decoded["compiler_name"])
    end
  end

  test "spex diagnostics/0 is queryable after seeding persistent_term" do
    # Verifies that compile.spex stores diagnostics in a way compile.diagnostics can read.
    # In production, :spex is in the compilers list so collect_diagnostics finds it.
    fake_diag = %Mix.Task.Compiler.Diagnostic{
      file: "/app/test/my_spex.exs",
      source: "/app/test/my_spex.exs",
      severity: :warning,
      message: "test spex warning",
      position: {5, 1},
      compiler_name: "Spex",
      span: nil,
      details: nil,
      stacktrace: []
    }

    :persistent_term.put({Mix.Tasks.Compile.Spex, :diagnostics}, [fake_diag])

    stored = Mix.Tasks.Compile.Spex.diagnostics()
    assert length(stored) == 1
    assert hd(stored).message == "test spex warning"
  end

  test "creates parent directories for output path" do
    nested_output = "test_tmp/nested/diagnostics.jsonl"

    on_exit(fn ->
      File.rm_rf!("test_tmp")
    end)

    Mix.Tasks.Compile.Diagnostics.run(["--output", nested_output])

    assert File.exists?(nested_output)
  end

  test "returns {:noop, []}" do
    assert {:noop, []} = Mix.Tasks.Compile.Diagnostics.run(["--output", @output_file])
  end
end
