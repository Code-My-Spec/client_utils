defmodule ClientUtils.Evidence.JourneyEvidenceTest do
  @moduledoc """
  The journey evidence, end to end: Credo's CMS0004 flags a journey with no
  walk; a walk run with the evidence formatters writes a CTRF report tagged by
  journey and stage; and `mix client_utils.journey_coverage` fails on a stage
  that did not pass, or when there is no report at all.

  The walk is a throwaway Mix project with no deps (Mix prunes any code path
  it was not given), so it loads the formatters' source with `elixir -r`.
  """
  use ExUnit.Case, async: true

  @walk """
  defmodule WalkTest do
    use ExUnit.Case
    @moduletag journey: "walk"

    @tag stage: "starts"
    test "starts", do: assert(true)

    @tag stage: "ends"
    test "ends", do: assert(1 + 1 == 2)
  end
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "journey_evidence_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    write!(dir, "mix.exs", """
    defmodule Throwaway.MixProject do
      use Mix.Project
      def project, do: [app: :throwaway, version: "0.1.0", deps: []]
    end
    """)

    write!(dir, "test/test_helper.exs", "ExUnit.start(exclude: [:journey])\n")
    write!(dir, "test/journeys/walk_test.exs", @walk)
    write!(dir, ".code_my_spec/journeys/walk.yml", "stages:\n  - id: starts\n  - id: ends\n")
    write!(dir, ".code_my_spec/journeys/ghost.yml", "stages:\n  - id: haunts\n")
    {_, 0} = System.cmd("git", ["init", "-q"], cd: dir)
    %{dir: dir}
  end

  test "a ghost journey is flagged, a walk writes CTRF, and coverage fails the run without it",
       %{dir: dir} do
    {sarif, _} = credo(dir)

    assert [%{"message" => %{"text" => "journey ghost has no test in test/journeys/"}} = ghost] =
             JSON.decode!(sarif)["runs"] |> hd() |> Map.fetch!("results")

    assert [%{"physicalLocation" => %{"artifactLocation" => %{"uri" => uri}}}] =
             ghost["locations"]

    assert uri =~ "ghost.yml"

    assert {_, 0} = walk(dir)
    assert [ctrf] = Path.wildcard(Path.join(dir, ".code_my_spec/evidence/*.ctrf.json"))
    tags = for t <- JSON.decode!(File.read!(ctrf))["results"]["tests"], do: Enum.sort(t["tags"])
    assert Enum.sort(tags) == [~w(journey:walk stage:ends), ~w(journey:walk stage:starts)]

    assert {out, 1} = coverage(dir)
    assert [%{"ruleId" => "stage-not-passed"} = haunts] = results(out)
    assert haunts["message"]["text"] =~ "stage haunts of ghost"

    File.rm!(Path.join(dir, ".code_my_spec/journeys/ghost.yml"))
    assert {out, 0} = coverage(dir)
    assert results(out) == []

    write!(dir, "test/journeys/walk_test.exs", String.replace(@walk, "1 + 1 == 2", "1 + 1 == 3"))
    File.rm_rf!(Path.join(dir, ".code_my_spec/evidence"))
    assert {_, 2} = walk(dir)
    assert {out, 1} = coverage(dir)
    assert [%{"message" => %{"text" => "stage ends of walk" <> _}}] = results(out)

    File.rm_rf!(Path.join(dir, ".code_my_spec/evidence"))
    assert {out, status} = coverage(dir)
    assert status != 0
    assert out =~ "no CTRF report holds a journey test"
  end

  defp write!(dir, path, body) do
    path = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end

  defp credo(dir) do
    config = Path.join(dir, "credo.exs")

    File.write!(
      config,
      inspect(%{
        configs: [
          %{
            name: "default",
            files: %{included: [Path.join(dir, "test/")]},
            checks: %{
              enabled: [
                {ClientUtils.Check.JourneyCoverage,
                 [journeys: Path.join(dir, ".code_my_spec/journeys/*.yml")]}
              ]
            }
          }
        ]
      })
    )

    System.cmd("mix", ["credo", "--config-file", config, "--strict", "--format", "sarif"],
      env: [{"MIX_ENV", "test"}]
    )
  end

  defp walk(dir) do
    clean =
      for v <-
            ~w(MIX_EXS MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_LOCKFILE MIX_TEST_PARTITION),
          do: {v, nil}

    System.cmd("elixir", ClientUtils.EvidenceCase.exunit() ++ ~w(--seed 0 --include journey),
      cd: dir,
      env: [{"MIX_ENV", "test"} | clean],
      stderr_to_stdout: true
    )
  end

  defp coverage(dir) do
    System.cmd("mix", ["client_utils.journey_coverage", dir],
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )
  end

  defp results(out), do: hd(JSON.decode!(out)["runs"])["results"]
end
