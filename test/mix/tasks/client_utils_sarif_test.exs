defmodule Mix.Tasks.ClientUtils.SarifTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "a passing command leaves no results, a failing one leaves its output, and the exit is the command's",
       %{tmp_dir: dir} do
    pass = Path.join(dir, "pass.sarif")
    fail = Path.join(dir, "fail.sarif")

    assert {_, 0} = System.cmd("mix", ["client_utils.sarif", pass, "--", "true"])

    assert {_, 3} =
             System.cmd("mix", ["client_utils.sarif", fail, "--", "sh", "-c", "echo boom; exit 3"])

    assert %{"runs" => [%{"tool" => %{"driver" => %{"name" => "pass"}}, "results" => []}]} =
             pass |> File.read!() |> Jason.decode!()

    assert %{
             "runs" => [
               %{"results" => [%{"level" => "error", "message" => %{"text" => "boom\n"}}]}
             ]
           } =
             fail |> File.read!() |> Jason.decode!()

    assert %{"analyzers" => %{"pass" => %{"exit" => 0}, "fail" => %{"exit" => 3}}} =
             dir |> Path.join("meta.json") |> File.read!() |> Jason.decode!()
  end

  test "a failure printed mid-run by any command is its own result, however much follows it",
       %{tmp_dir: dir} do
    path = Path.join(dir, "spex.sarif")

    script =
      "printf '  1) test shares (ShareSpex)\\n     test/spex/share_spex.exs:52\\n     ** (MatchError) boom\\n\\n'; " <>
        "head -c 6000 /dev/zero | tr '\\0' .; printf '\\nFinished in 1.0 seconds\\n'; exit 1"

    assert {_, 1} = System.cmd("mix", ["client_utils.sarif", path, "--", "sh", "-c", script])

    assert %{"runs" => [%{"results" => [%{"message" => %{"text" => text}} = result]}]} =
             path |> File.read!() |> Jason.decode!()

    assert text =~ "MatchError"

    assert get_in(result, ["locations", Access.at(0), "physicalLocation", "region", "startLine"]) ==
             52
  end
end
