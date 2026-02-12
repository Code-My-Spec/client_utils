defmodule Mix.Tasks.Compile.Spex do
  use Mix.Task.Compiler

  @moduledoc """
  Compiles `.exs` files matching a glob pattern and returns their diagnostics.

  Add `:spex` to your project's compilers list so it runs as part of `mix compile`:

      def project do
        [
          compilers: Mix.compilers() ++ [:spex],
          ...
        ]
      end

  ## Project configuration

  Configure the glob pattern under the `:spex` key:

      def project do
        [
          spex: [pattern: "test/spex/**/*_spex.exs"],
          ...
        ]
      end

  ## Flags

    * `--spex-pattern` (`-p`) - glob pattern for .exs files to compile
  """

  @opts [
    strict: [spex_pattern: :string],
    aliases: [p: :spex_pattern]
  ]

  @impl true
  def run(argv) do
    if Mix.env() != :test do
      {:noop, []}
    else
      do_run(argv)
    end
  end

  defp do_run(argv) do
    {args, _, _} = OptionParser.parse(argv, @opts)
    config = Keyword.get(Mix.Project.config(), :spex, [])

    pattern =
      Keyword.get(args, :spex_pattern, Keyword.get(config, :pattern))

    result =
      if is_nil(pattern) do
        {:noop, []}
      else
        compile_exs_files(pattern)
      end

    {status, diags} = result
    :persistent_term.put({__MODULE__, :diagnostics}, diags)
    {status, diags}
  end

  @impl true
  def diagnostics do
    :persistent_term.get({__MODULE__, :diagnostics}, [])
  end

  defp compile_exs_files(pattern) do
    files = Path.wildcard(pattern)

    if Enum.empty?(files) do
      {:noop, []}
    else
      Mix.Task.run("loadpaths")

      # Boundary (and similar tracers) unregister themselves after :elixir finishes.
      # We temporarily re-add them so spex files get boundary-checked too.
      original_tracers = Code.get_compiler_option(:tracers)
      tracers = add_known_tracers(original_tracers)
      Code.put_compiler_option(:tracers, tracers)

      result =
        case Kernel.ParallelCompiler.compile(files,
               return_diagnostics: true,
               tracers: tracers
             ) do
          {:ok, modules, %{compile_warnings: warnings}} ->
            schedule_boundary_check(modules)
            {:ok, normalize_diagnostics(warnings)}

          {:error, errors, %{compile_warnings: warnings}} ->
            {:error, normalize_diagnostics(errors ++ warnings)}
        end

      Code.put_compiler_option(:tracers, original_tracers)

      result
    end
  end

  # ---------------------------------------------------------------------------
  # Boundary integration
  #
  # Boundary's after_compiler(:app) callback flushes references from non-app
  # modules (including spex modules) before running its check. We register our
  # own after_compiler(:app) callback which — because callbacks are LIFO — runs
  # BEFORE Boundary's flush, giving us access to the spex references.
  # ---------------------------------------------------------------------------

  @boundary_tracer Mix.Tasks.Compile.Boundary

  defp schedule_boundary_check(compiled_modules) do
    state_mod = Boundary.Mix.CompilerState

    if Code.ensure_loaded?(state_mod) and function_exported?(state_mod, :references, 0) do
      :persistent_term.put({__MODULE__, :spex_modules}, compiled_modules)
      Mix.Task.Compiler.after_compiler(:app, &check_spex_boundaries/1)
    end
  rescue
    _ -> :ok
  end

  defp check_spex_boundaries({status, diagnostics} = outcome) when status in [:ok, :noop] do
    boundary_mod = Boundary
    view_mod = Boundary.Mix.View
    state_mod = Boundary.Mix.CompilerState

    with true <- Code.ensure_loaded?(boundary_mod),
         true <- Code.ensure_loaded?(view_mod),
         true <- Code.ensure_loaded?(state_mod),
         true <- function_exported?(boundary_mod, :errors, 2),
         true <- function_exported?(view_mod, :build, 0) do
      spex_modules = :persistent_term.get({__MODULE__, :spex_modules}, [])

      if Enum.empty?(spex_modules) do
        outcome
      else
        do_check_spex_boundaries(
          spex_modules,
          state_mod,
          view_mod,
          boundary_mod,
          status,
          diagnostics
        )
      end
    else
      _ -> outcome
    end
  rescue
    _ -> outcome
  end

  defp check_spex_boundaries(outcome), do: outcome

  defp do_check_spex_boundaries(
         spex_modules,
         state_mod,
         view_mod,
         boundary_mod,
         status,
         diagnostics
       ) do
    spex_module_set = MapSet.new(spex_modules)

    spex_refs =
      state_mod.references()
      |> Enum.filter(&MapSet.member?(spex_module_set, &1.from))

    if Enum.empty?(spex_refs) do
      {status, diagnostics}
    else
      apply(Boundary.Mix, :load_app, [])
      view = view_mod.build()
      view = classify_spex_modules(view, spex_modules)

      boundary_errors =
        boundary_mod.errors(view, spex_refs)
        |> Enum.filter(fn
          {:invalid_reference, _} -> true
          _ -> false
        end)
        |> Enum.map(&boundary_error_to_diagnostic/1)
        |> Enum.sort_by(&{&1.file, &1.position})

      print_diagnostics(boundary_errors)

      existing_diags = :persistent_term.get({__MODULE__, :diagnostics}, [])
      :persistent_term.put({__MODULE__, :diagnostics}, existing_diags ++ boundary_errors)

      {status, diagnostics ++ boundary_errors}
    end
  end

  defp classify_spex_modules(view, spex_modules) do
    boundaries = view.classifier.boundaries
    main_app = view.main_app

    new_module_mappings =
      for module <- spex_modules,
          boundary_name = find_boundary_for_module(module, boundaries),
          boundary_name != nil,
          into: %{},
          do: {module, boundary_name}

    new_module_to_app =
      for module <- spex_modules, into: %{}, do: {module, main_app}

    view
    |> update_in([:classifier, :modules], &Map.merge(&1, new_module_mappings))
    |> update_in([:module_to_app], &Map.merge(&1, new_module_to_app))
  end

  defp find_boundary_for_module(module, boundaries) do
    parts = Module.split(module)

    Enum.reduce_while(length(parts)..1//-1, nil, fn len, _acc ->
      candidate = parts |> Enum.take(len) |> Module.concat()

      if Map.has_key?(boundaries, candidate) do
        {:halt, candidate}
      else
        {:cont, nil}
      end
    end)
  end

  defp boundary_error_to_diagnostic({:invalid_reference, error}) do
    reason =
      case error.type do
        :normal ->
          "(references from #{inspect(error.from_boundary)} to #{inspect(error.to_boundary)} are not allowed)"

        :runtime ->
          "(runtime references from #{inspect(error.from_boundary)} to #{inspect(error.to_boundary)} are not allowed)"

        :not_exported ->
          "(module #{inspect(error.reference.to)} is not exported by its owner boundary #{inspect(error.to_boundary)})"

        :invalid_external_dep_call ->
          "(references from #{inspect(error.from_boundary)} to #{inspect(error.to_boundary)} are not allowed)"
      end

    %Mix.Task.Compiler.Diagnostic{
      compiler_name: "boundary",
      file: Path.relative_to_cwd(error.reference.file),
      message: "forbidden reference to #{inspect(error.reference.to)}\n  #{reason}",
      position: error.reference.line,
      severity: :warning,
      details: nil
    }
  end

  defp print_diagnostics([]), do: :ok

  defp print_diagnostics(diagnostics) do
    Mix.shell().info("")

    Enum.each(diagnostics, fn diag ->
      color = if diag.severity == :error, do: :red, else: :yellow
      pos = if is_integer(diag.position), do: ":#{diag.position}", else: ""
      location = if diag.file, do: "\n  #{diag.file}#{pos}\n", else: "\n"
      Mix.shell().info([:bright, color, "#{diag.severity}: ", :reset, diag.message, location])
    end)
  end

  defp add_known_tracers(existing) do
    if Code.ensure_loaded?(@boundary_tracer) and @boundary_tracer not in existing do
      [@boundary_tracer | existing]
    else
      existing
    end
  end

  defp normalize_diagnostics(diagnostics) do
    Enum.map(diagnostics, fn diag ->
      %Mix.Task.Compiler.Diagnostic{
        file: diag.file,
        position: diag.position,
        message: diag.message,
        severity: diag.severity,
        compiler_name: Map.get(diag, :compiler_name, "Spex"),
        details: Map.get(diag, :stacktrace)
      }
    end)
  end
end
