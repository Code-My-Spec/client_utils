defmodule ClientUtils.CiJustTest do
  @moduledoc """
  priv/ci.just: ci runs the journeys after the suite on the LiveView driver,
  never in a browser, under priv/time_limit.sh.
  """
  use ExUnit.Case, async: true

  @ci_just Path.expand("priv/ci.just")
  @time_limit Path.expand("priv/time_limit.sh")
  @journeys "--include journey test/journeys/*_test.exs"

  defp recipe(name) do
    {body, 0} = System.cmd("just", ["-f", @ci_just, "--show", name], stderr_to_stdout: true)
    String.split(body, "\n", trim: true)
  end

  defp index(lines, fragment), do: Enum.find_index(lines, &String.contains?(&1, fragment))

  test "ci runs certify, the hook, the suite, then the journeys" do
    ci = recipe("ci")

    steps =
      Enum.map(
        ["just certify", "just ci-extra", "run exunit -- {{ exunit }} ||", @journeys],
        &index(ci, &1)
      )

    assert Enum.all?(steps), inspect(steps)
    assert steps == Enum.sort(steps)
  end

  test "ci, retry and certify never drive a browser" do
    for name <- ~w(ci retry certify), line <- recipe(name) do
      refute line =~ ~r/CMS_E2E|CMS_JOURNEY_SLIDES_DIR|playwright|npm ci/, "#{name}: #{line}"
    end
  end

  test "the journey step runs under the time limit" do
    for name <- ~w(ci retry) do
      line = Enum.at(recipe(name), index(recipe(name), @journeys))
      assert line =~ ~s({{ time_limit }} 120 10 "journey step" -- {{ evidence }} run), name
    end
  end

  test "a step that ignores SIGTERM is killed and fails" do
    pids = Path.join(System.tmp_dir!(), "time_limit_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(pids) end)

    # A parent and a child, both ignoring SIGTERM, spinning.
    hang =
      "trap '' TERM; (trap '' TERM; echo $BASHPID >> #{pids}; while :; do :; done) & " <>
        "echo $$ >> #{pids}; while :; do :; done"

    started = System.monotonic_time(:millisecond)

    {out, status} =
      System.cmd(@time_limit, ["1", "1", "journey step", "--", "bash", "-c", hang],
        stderr_to_stdout: true
      )

    assert status == 124
    assert out =~ "ci: the journey step timed out after 1s and was killed"
    assert System.monotonic_time(:millisecond) - started < 10_000

    Process.sleep(300)

    for pid <- pids |> File.read!() |> String.split("\n", trim: true) do
      {_, alive} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
      refute alive == 0, "process #{pid} outlived the limit"
    end
  end

  test "a step inside the limit keeps its own status" do
    assert {_, 3} = System.cmd(@time_limit, ["30", "1", "x", "--", "bash", "-c", "exit 3"])
    assert {"hi\n", 0} = System.cmd(@time_limit, ["30", "1", "x", "--", "echo", "hi"])
  end
end
