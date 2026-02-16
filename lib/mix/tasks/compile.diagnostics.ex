defmodule Mix.Tasks.Compile.Diagnostics do
  use Mix.Task.Compiler

  @moduledoc """
  Registers `after_compiler` hooks that write diagnostics to a JSONL file.

  Add `:diagnostics` as the **first** compiler so the hooks are registered
  before `:elixir` runs. This ensures diagnostics are written even when a
  syntax error aborts the compiler chain.

      def project do
        [
          compilers: [:diagnostics] ++ Mix.compilers() ++ [:spex],
          diagnostics: [output: "diagnostics.jsonl"],
          ...
        ]
      end

  ## Options

    * `:output` - output file path, defaults to `"diagnostics.jsonl"`.
      Can also be set via the `DIAGNOSTICS_OUTPUT` env var.

  ## Project configuration

  Options can be set under the `:diagnostics` key:

      def project do
        [
          compilers: [:diagnostics] ++ Mix.compilers() ++ [:spex],
          diagnostics: [output: "build/diagnostics.jsonl"],
          ...
        ]
      end
  """

  @impl true
  def run(_argv) do
    output = resolve_output()

    for compiler <- [:elixir, :app] do
      Mix.Task.Compiler.after_compiler(compiler, fn {status, diags} ->
        write_diagnostics(output, diags)
        {status, diags}
      end)
    end

    {:noop, []}
  end

  @doc """
  Writes diagnostics to the output file.

  Merges diagnostics passed via `extra_diagnostics` (from the after_compiler
  callback) with those queried from every compiler that exposes `diagnostics/0`,
  deduplicating by file + position + message.
  """
  def write_diagnostics(output, extra_diagnostics \\ []) do
    collected = collect_diagnostics()

    all =
      (collected ++ extra_diagnostics)
      |> Enum.map(&normalize_diagnostic/1)
      |> Enum.reject(&is_nil/1)
      |> deduplicate()

    output_dir = Path.dirname(output)

    if output_dir != "." do
      File.mkdir_p!(output_dir)
    end

    File.write!(output, ClientUtils.DiagnosticsFormat.to_jsonl(all))
  end

  defp normalize_diagnostic(%Mix.Task.Compiler.Diagnostic{} = d), do: d

  defp normalize_diagnostic(%SyntaxError{} = e) do
    %Mix.Task.Compiler.Diagnostic{
      file: e.file,
      source: e.file,
      position: e.line,
      message: e.description,
      severity: :error,
      compiler_name: "Elixir",
      span: nil,
      details: nil,
      stacktrace: []
    }
  end

  defp normalize_diagnostic(other) do
    Mix.shell().error(
      "warning: compile.diagnostics received unexpected diagnostic type: #{inspect(other)}"
    )

    nil
  end

  defp resolve_output do
    config = Keyword.get(Mix.Project.config(), :diagnostics, [])

    System.get_env("DIAGNOSTICS_OUTPUT") ||
      Keyword.get(config, :output, "diagnostics.jsonl")
  end

  defp collect_diagnostics do
    compilers = Mix.Project.config()[:compilers] || Mix.compilers()

    Enum.flat_map(compilers, fn compiler ->
      task = Mix.Task.get("compile.#{compiler}")

      if task && task != __MODULE__ && function_exported?(task, :diagnostics, 0) do
        task.diagnostics()
      else
        []
      end
    end)
  end

  defp deduplicate(diagnostics) do
    Enum.uniq_by(diagnostics, fn d -> {d.file, d.position, d.message} end)
  end
end
