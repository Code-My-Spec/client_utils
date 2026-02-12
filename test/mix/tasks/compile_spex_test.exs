defmodule Mix.Tasks.Compile.SpexTest do
  use ExUnit.Case

  setup do
    # Clean up persistent_term between tests
    on_exit(fn ->
      try do
        :persistent_term.erase({Mix.Tasks.Compile.Spex, :diagnostics})
      rescue
        ArgumentError -> :ok
      end
    end)

    # Clean up any modules defined by fixture compilation
    on_exit(fn ->
      for mod <- [FixtureSpex.WarningSpex, FixtureSpex.CleanSpex] do
        :code.purge(mod)
        :code.delete(mod)
      end
    end)

    :ok
  end

  test "returns {:noop, []} when no pattern is configured" do
    assert {:noop, []} = Mix.Tasks.Compile.Spex.run([])
  end

  test "returns {:noop, []} when pattern matches no files" do
    assert {:noop, []} = Mix.Tasks.Compile.Spex.run(["--spex-pattern", "nonexistent/**/*.exs"])
  end

  test "compiles .exs files and captures warnings as diagnostics" do
    {status, diagnostics} =
      Mix.Tasks.Compile.Spex.run([
        "--spex-pattern",
        "fixtures/spex/warning_spex.exs"
      ])

    assert status == :ok
    assert length(diagnostics) > 0

    warning = Enum.find(diagnostics, &(&1.severity == :warning))
    assert warning
    assert warning.message =~ "unused_var"
    assert warning.compiler_name == "Spex"
    assert String.ends_with?(warning.file, "warning_spex.exs")
  end

  test "compiles clean .exs files with no diagnostics" do
    {status, diagnostics} =
      Mix.Tasks.Compile.Spex.run([
        "--spex-pattern",
        "fixtures/spex/clean_spex.exs"
      ])

    assert status == :ok
    assert diagnostics == []
  end

  test "diagnostics/0 returns stored diagnostics after run" do
    Mix.Tasks.Compile.Spex.run([
      "--spex-pattern",
      "fixtures/spex/warning_spex.exs"
    ])

    stored = Mix.Tasks.Compile.Spex.diagnostics()
    assert length(stored) > 0
    assert hd(stored).message =~ "unused_var"
  end

  test "diagnostics/0 returns empty list when never run" do
    assert Mix.Tasks.Compile.Spex.diagnostics() == []
  end
end
