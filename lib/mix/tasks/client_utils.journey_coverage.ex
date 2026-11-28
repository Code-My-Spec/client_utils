defmodule Mix.Tasks.ClientUtils.JourneyCoverage do
  @moduledoc """
  Every journey stage passed in the last journeys run.

      mix client_utils.journey_coverage [<project dir>]

  Reads the project's `.code_my_spec/journeys/*.yml` and the newest CTRF report
  in its `.code_my_spec/evidence/` that holds a journey test, and prints SARIF on
  stdout: one error per stage that has no passed test tagged `journey:<slug>`
  and `stage:<id>` (skipped is not passed), and one when the report was made
  at another tree than the working tree's. Exits 1 when there is any, and fails
  when no report holds a journey test. Needs `yaml_elixir`.
  """
  @shortdoc "Fails unless every journey stage passed in the last journeys run"

  use Mix.Task

  alias ClientUtils.Evidence.CTRFFormatter

  @impl true
  def run(argv) do
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)
    results = File.cd!(List.first(argv) || ".", &results/0)

    IO.puts(
      JSON.encode!(%{
        "version" => "2.1.0",
        "$schema" => "https://json.schemastore.org/sarif-2.1.0.json",
        "runs" => [
          %{"tool" => %{"driver" => %{"name" => "journey-coverage"}}, "results" => results}
        ]
      })
    )

    if results != [], do: exit({:shutdown, 1})
  end

  defp results do
    ctrf =
      ".code_my_spec/evidence/*.ctrf.json"
      |> Path.wildcard()
      |> Enum.filter(&walk?/1)
      |> Enum.max_by(&File.stat!(&1).mtime, fn ->
        Mix.raise("no CTRF report holds a journey test")
      end)

    passed =
      for t <- tests(ctrf),
          t["status"] == "passed",
          into: MapSet.new(),
          do: MapSet.new(t["tags"] || [])

    stale(ctrf) ++
      for path <- Enum.sort(Path.wildcard(".code_my_spec/journeys/*.yml")),
          slug = Path.basename(path, ".yml"),
          {:ok, yaml} = YamlElixir.read_from_file(path),
          stage <- yaml["stages"] || [],
          not Enum.any?(
            passed,
            &MapSet.subset?(MapSet.new(["journey:#{slug}", "stage:#{stage["id"]}"]), &1)
          ) do
        %{
          "ruleId" => "stage-not-passed",
          "level" => "error",
          "message" => %{
            "text" => "stage #{stage["id"]} of #{slug} has no passed test in #{ctrf}"
          },
          "locations" => [%{"physicalLocation" => %{"artifactLocation" => %{"uri" => path}}}]
        }
      end
  end

  # A report with no tree (no commit yet) cannot be stale.
  defp stale(ctrf) do
    made = JSON.decode!(File.read!(ctrf))["results"]["environment"]["extra"]["codemyspec.tree"]
    now = made && CTRFFormatter.tested_tree()

    if made && now != made do
      [
        %{
          "ruleId" => "report-stale",
          "level" => "error",
          "message" => %{"text" => "#{ctrf} was made at tree #{made}, not this one (#{now})"},
          "locations" => [%{"physicalLocation" => %{"artifactLocation" => %{"uri" => ctrf}}}]
        }
      ]
    else
      []
    end
  end

  defp tests(path), do: JSON.decode!(File.read!(path))["results"]["tests"]

  defp walk?(path),
    do: Enum.any?(tests(path), &Enum.any?(&1["tags"] || [], fn t -> t =~ ~r/^journey:/ end))
end
