# Compiled only where the project has credo (an optional dependency).
if Code.ensure_loaded?(Credo.Check) do
  defmodule ClientUtils.Check.JourneyCoverage do
    @moduledoc """
    Credo check that holds `test/journeys/*_test.exs` to `.code_my_spec/journeys/*.yml`:
    one file per journey (`@moduletag journey: "<slug>"`), one test per stage
    (`@tag stage: "<id>"`), in the YAML's order.
    """

    use Credo.Check,
      id: "CMS0004",
      base_priority: :high,
      category: :warning,
      run_on_all: true,
      param_defaults: [journeys: ".code_my_spec/journeys/*.yml"],
      explanations: [
        check: """
        A journey is covered when its walk tests every stage, in order.

        Each `.code_my_spec/journeys/<slug>.yml` has one test file under
        `test/journeys/` that says which journey it walks:

            @moduletag journey: "<slug>"

        and one test per stage, tagged with the stage's `id:` and in the YAML's
        order, since a stage starts where the one before it ended:

            @tag stage: "signs-in"
            test "the newcomer registers and lands signed in", ctx do

        Flagged: a journey with no test file, a stage with no test, a tag naming
        no stage of the journey, a stage out of order, and a journey file that
        names no journey. A stage no walk can test is removed from the YAML.
        """,
        params: [journeys: "The glob of the journey files."]
      ]

    @doc false
    @impl true
    def run_on_all_source_files(exec, source_files, params) do
      {:ok, _} = Application.ensure_all_started(:yaml_elixir)
      glob = Params.get(params, :journeys, __MODULE__)
      journeys = Map.new(Path.wildcard(glob), &read_journey/1)
      walks = Enum.filter(source_files, &walk?/1)

      walk_issues = Enum.flat_map(walks, &walk_issues(&1, journeys, glob, params))

      # Only a run over the tests can say a journey has none.
      missing =
        if Enum.any?(source_files, &(&1.filename =~ ~r{(^|/)test/})),
          do: untested(journeys, walks, params),
          else: []

      append_issues_and_timings(walk_issues ++ missing, exec)
      :ok
    end

    defp read_journey(path) do
      {:ok, yaml} = YamlElixir.read_from_file(path)
      ids = for stage <- yaml["stages"] || [], do: stage["id"]
      {Path.basename(path, ".yml"), %{path: path, ids: ids}}
    end

    defp walk?(%SourceFile{filename: f}), do: f =~ ~r{(^|/)test/journeys/[^/]+_test\.exs$}

    defp walk_issues(source_file, journeys, glob, params) do
      meta = IssueMeta.for(source_file, params)
      {slug, line, tags} = tags_of(source_file)

      case journeys[slug] do
        nil ->
          [issue(meta, "names no journey in #{glob} (`@moduletag journey:`)", line || 1)]

        %{ids: ids} ->
          stage_issues(meta, ids, tags) ++
            for id <- ids,
                id not in Enum.map(tags, &elem(&1, 0)),
                do: issue(meta, "stage #{id} of #{slug} has no test", line)
      end
    end

    defp stage_issues(meta, ids, tags) do
      {issues, _} =
        Enum.reduce(tags, {[], -1}, fn {id, line}, {issues, last} ->
          index = Enum.find_index(ids, &(&1 == id))

          cond do
            is_nil(index) ->
              {[issue(meta, "no stage #{id} in this journey", line) | issues], last}

            index <= last ->
              {[issue(meta, "stage #{id} is out of order", line) | issues], last}

            true ->
              {issues, index}
          end
        end)

      Enum.reverse(issues)
    end

    defp untested(journeys, walks, params) do
      tested = MapSet.new(walks, &elem(tags_of(&1), 0))

      for {slug, %{path: path}} <- Enum.sort(journeys), slug not in tested do
        source = path |> File.read!() |> SourceFile.parse(path)
        issue(IssueMeta.for(source, params), "journey #{slug} has no test in test/journeys/", 1)
      end
    end

    # {journey slug, its line, [{stage id, line}] in file order}
    defp tags_of(source_file) do
      {slug, line, tags} =
        Credo.Code.prewalk(source_file, &collect/2, {nil, nil, []})

      {slug, line, Enum.reverse(tags)}
    end

    defp collect({:@, meta, [{:moduletag, _, [[journey: slug]]}]} = ast, {_, _, tags}),
      do: {ast, {slug, meta[:line], tags}}

    defp collect({:@, meta, [{:tag, _, [[stage: id]]}]} = ast, {slug, line, tags}),
      do: {ast, {slug, line, [{id, meta[:line]} | tags]}}

    defp collect(ast, acc), do: {ast, acc}

    defp issue(meta, message, line),
      do: format_issue(meta, message: message, line_no: line, trigger: "@tag")
  end
end
