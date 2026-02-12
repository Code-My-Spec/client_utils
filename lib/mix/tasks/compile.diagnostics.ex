defmodule Mix.Tasks.Compile.Diagnostics do
  use Mix.Task.Compiler

  @moduledoc """
  Collects diagnostics from all previous compilers and writes them to a JSONL file.

  Add `:diagnostics` as the LAST compiler in your project's compilers list:

      def project do
        [
          compilers: Mix.compilers() ++ [:spex, :diagnostics],
          diagnostics: [output: "diagnostics.jsonl"],
          ...
        ]
      end

  When this compiler runs, it queries `diagnostics/0` on every compiler that
  came before it in the list and writes them all to the output file.

  ## Flags

    * `--output` (`-o`) - output file path, defaults to `"diagnostics.jsonl"`

  ## Project configuration

  Options can also be set under the `:diagnostics` key in your project config:

      def project do
        [
          diagnostics: [output: "build/diagnostics.jsonl"],
          ...
        ]
      end
  """

  @opts [
    strict: [output: :string],
    aliases: [o: :output]
  ]

  @impl true
  def run(argv) do
    {args, _, _} = OptionParser.parse(argv, @opts)
    config = Keyword.get(Mix.Project.config(), :diagnostics, [])

    output =
      System.get_env("DIAGNOSTICS_OUTPUT") ||
        Keyword.get(args, :output, Keyword.get(config, :output, "diagnostics.jsonl"))

    diagnostics = collect_diagnostics()

    output_dir = Path.dirname(output)

    if output_dir != "." do
      File.mkdir_p!(output_dir)
    end

    File.write!(output, ClientUtils.DiagnosticsFormat.to_jsonl(diagnostics))

    {:noop, []}
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
end
