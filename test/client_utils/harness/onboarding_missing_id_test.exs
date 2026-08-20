defmodule ClientUtils.Harness.Onboarding.MissingIdTest do
  @moduledoc """
  `onboard/2` with no harness id must not write a broken address.

  It used to: `harness_id` defaulted to `nil`, and `"#{nil}"` interpolates as
  `""` rather than the atom's name — so `anthropic_url/2` silently rendered
  `http://localhost:4004/api/harnesses/`, the exact dangling prefix
  `check/2`'s own `blank_or_invalid?/2` exists to catch. `merge_env/2` then
  rejected `CMS_HARNESS_ID` (a real `nil`) but not `ANTHROPIC_BASE_URL` (a
  string, just an empty one), so the file came out with one broken key and
  one silently missing key — and `report_onboard/1` printed "onboarded:"
  over it regardless. Measured cost: a working copy addressed the *parent*
  checkout's harness for three days (`c79ee092`), the incident `check/2`'s
  own moduledoc documents. `check/2` was fixed to detect this state; `onboard/2`
  itself was never fixed to stop producing it — this pins that it no longer
  does, and that a later run without an id cannot erase a real one a run
  with an id already wrote.
  """

  use ExUnit.Case, async: true

  alias ClientUtils.Harness.Onboarding

  @root "/workspace/app"
  @harness "d1c8f8f5-1111-2222-3333-444455556666"

  defmodule FakeIO do
    @moduledoc false
    @behaviour ClientUtils.Harness.Onboarding.IO

    @impl true
    def read_file(_root, path) do
      case Process.get({:settings, path}) do
        nil -> {:error, :enoent}
        contents -> {:ok, contents}
      end
    end

    @impl true
    def file_exists?(_root, path), do: Process.get({:settings, path}) != nil

    @impl true
    def write_file(_root, path, contents) do
      Process.put({:settings, path}, contents)
      :ok
    end

    @impl true
    def cmd(_root, _command, _args, _opts \\ []), do: {"", 0}
  end

  defp onboard(opts \\ []) do
    Onboarding.onboard(@root, Keyword.merge([io: FakeIO, app: :my_app], opts))
  end

  defp written_env do
    {:ok, contents} = FakeIO.read_file(@root, Onboarding.settings_path())
    Jason.decode!(contents)["env"]
  end

  test "no id writes no address at all, not a broken one" do
    onboard()

    env = written_env()

    refute Map.has_key?(env, "ANTHROPIC_BASE_URL"),
           "no id means no route — a dangling /api/harnesses/ prefix is not a fallback, it is the bug"

    refute Map.has_key?(env, "CMS_HARNESS_ID")
  end

  test "no id leaves the copy reporting as not onboarded" do
    onboard()

    assert %{onboarded: false, missing: missing} = Onboarding.check(@root, io: FakeIO)
    assert "CMS_HARNESS_ID" in missing

    refute "ANTHROPIC_BASE_URL" in missing,
           "opt-in and default off — see relay_model_turns? — so its absence is not what " <>
             "makes this copy unonboarded"
  end

  test "no id still records the partition — that part never needed a server" do
    onboard()

    assert written_env()["MIX_TEST_PARTITION"] == Onboarding.partition_name(@root)
  end

  test "a real id addresses MCP but does not relay model turns by default" do
    onboard(harness_id: @harness)

    env = written_env()

    assert env["CMS_HARNESS_ID"] == @harness

    refute Map.has_key?(env, "ANTHROPIC_BASE_URL"),
           "the harness's Anthropic proxy only forwards /v1/messages — routing an " <>
             "interactive session's model turns through it silently breaks anything " <>
             "else the Claude Code client needs (/remote-control, measured), so this " <>
             "has to be asked for with relay_model_turns: true, not assumed from an id"
  end

  test "relay_model_turns: true writes the model-turn address too" do
    onboard(harness_id: @harness, relay_model_turns: true)

    env = written_env()

    assert env["CMS_HARNESS_ID"] == @harness
    assert env["ANTHROPIC_BASE_URL"] == Onboarding.anthropic_url("http://localhost:4004", @harness)
  end

  test "re-running with no id does not erase an id a prior run wrote" do
    onboard(harness_id: @harness)
    onboard()

    env = written_env()

    assert env["CMS_HARNESS_ID"] == @harness,
           "a bare re-run — someone re-running the printed remedy out of habit, or a CI step " <>
             "that always calls this — must not blank out an id a real run already recorded"
  end

  test "re-running with no id does not erase a model-turn address a prior run opted into" do
    onboard(harness_id: @harness, relay_model_turns: true)
    onboard()

    env = written_env()

    assert env["ANTHROPIC_BASE_URL"] == Onboarding.anthropic_url("http://localhost:4004", @harness),
           "a bare re-run must not silently revoke an address a prior, opted-in run wrote"
  end

  test "the printed report never claims a copy is addressed when it is not" do
    report = onboard()

    assert report.harness_id == nil
  end

  test "the printed report reflects what actually landed, not just this run's option" do
    onboard(harness_id: @harness)
    report = onboard()

    assert report.harness_id == @harness,
           "the file still carries a real address after a bare re-run — the report saying " <>
             "nil here would tell someone to go fetch an id they do not need"
  end
end
