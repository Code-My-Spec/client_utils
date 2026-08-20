defmodule ClientUtils.Harness.Onboarding.CheckTest do
  @moduledoc """
  `--check` answers about the keys onboarding writes, not about a file.

  It used to decide from `io.exists?(root, settings_path())` alone. A run that
  refuses partway leaves that file behind — written by an earlier attempt — so
  the one state anybody runs `--check` to diagnose is the exact state it got
  wrong. The measured output printed

      onboarded: /…/worktrees/intake-on-home
        harness id: d1c8f8f5-…
        hooks:      skipped — /opt/homebrew/bin/cms-mcp-relay is too old

  two lines apart, while `CMS_HARNESS_ID` was absent and `ANTHROPIC_BASE_URL`
  was `http://localhost:4004/api/harnesses/` — the prefix with no id on it,
  which is not a route to anything.

  What it cost: the copy addressed the *parent* checkout's harness for three
  days. Hooks answered, MCP answered, requirements computed — all about a
  working copy nobody was editing, while this one went unscanned (`c79ee092`).

  The moduledoc on `check/2` is the specification these pin: "Absence has to
  report itself. A missing thing that produces no error where it is missing
  surfaces somewhere else wearing another failure's costume."
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

  defp put_settings(env) do
    Process.put(
      {:settings, Onboarding.settings_path()},
      Jason.encode!(%{"env" => env})
    )
  end

  defp put_hooks_config(harness_id) do
    Process.put(
      {:settings, Onboarding.harness_config_path()},
      Jason.encode!(%{"harness_id" => harness_id, "project_id" => nil, "root" => @root})
    )
  end

  defp check, do: Onboarding.check(@root, io: FakeIO)

  defp complete_env do
    %{
      "CMS_HARNESS_ID" => @harness,
      "MIX_TEST_PARTITION" => "h1a2b3c4d",
      "ANTHROPIC_BASE_URL" => Onboarding.anthropic_url("http://localhost:4004", @harness)
    }
  end

  test "a copy with every key is onboarded" do
    put_settings(complete_env())
    put_hooks_config(@harness)

    assert %{onboarded: true, missing: []} = check()
  end

  test "a settings file that exists but carries nothing is not onboarded" do
    put_settings(%{})

    status = check()

    refute status.onboarded,
           """
           This is the state `--check` exists to diagnose: a run that refused
           partway leaves the file behind. Deciding from existence answered
           `onboarded:` for a copy that then addressed the wrong harness for
           three days.
           """

    assert "CMS_HARNESS_ID" in status.missing
  end

  test "a base URL with no id on it is not a route to anything" do
    put_settings(%{
      complete_env()
      | "ANTHROPIC_BASE_URL" => "http://localhost:4004/api/harnesses/"
    })

    put_hooks_config(@harness)

    status = check()

    refute status.onboarded,
           "the measured failure had exactly this value — the prefix, no id"

    assert status.missing == ["ANTHROPIC_BASE_URL"],
           "and the other two keys were fine, which is why it read as onboarded"
  end

  test "an absent harness id is named" do
    put_settings(Map.delete(complete_env(), "CMS_HARNESS_ID"))
    put_hooks_config(@harness)

    assert %{onboarded: false, missing: ["CMS_HARNESS_ID"]} = check()
  end

  test "a blank value counts as missing" do
    put_settings(%{complete_env() | "CMS_HARNESS_ID" => "   "})
    put_hooks_config(@harness)

    assert %{onboarded: false, missing: ["CMS_HARNESS_ID"]} = check()
  end

  test "no settings file at all reports every key rather than erroring" do
    status = check()

    refute status.onboarded

    assert Enum.sort(status.missing) ==
             Enum.sort([
               "CMS_HARNESS_ID",
               "MIX_TEST_PARTITION",
               "HARNESS_CONFIG"
             ]),
           "a copy that was never onboarded is the ordinary case, not a special one — " <>
             "ANTHROPIC_BASE_URL is opt-in and not part of this list, see relay_model_turns?"
  end

  test "settings addressed but hooks config absent is named too" do
    put_settings(complete_env())

    assert %{onboarded: false, missing: ["HARNESS_CONFIG"]} = check()
  end

  # This test used to pin `remedy: "mix harness.onboard"` for exactly this
  # state, reasoning that "the write is a merge, so re-running repairs without
  # disturbing anything the operator put there". The merge part is true and is
  # covered elsewhere; it is a different question from whether the bare command
  # can *supply* what is missing. It cannot: nothing in a generated application
  # mints a harness id, so a bare re-run completes, reports itself, and leaves
  # `CMS_HARNESS_ID` and `HARNESS_CONFIG` exactly as absent as before.
  #
  # Measured in the devbox on a stock generated project, 2026-08-20: `--check`
  # printed `missing: CMS_HARNESS_ID, HARNESS_CONFIG` and `run: mix
  # harness.onboard`, which had just run and had just said `onboarded:`. Advice
  # that loops is worse than no advice, because it is followed.
  test "a copy missing its id is told to supply one" do
    put_settings(%{})

    assert %{remedy: remedy} = check()
    assert remedy =~ "--id"
  end

  test "a copy missing only the partition is told the bare command, which does fix it" do
    put_settings(%{
      "CMS_HARNESS_ID" => "d1c8f8f5-1111-2222-3333-444455556666"
    })

    put_hooks_config("d1c8f8f5-1111-2222-3333-444455556666")

    assert %{missing: ["MIX_TEST_PARTITION"], remedy: "mix harness.onboard"} = check(),
           "the partition is assigned by onboarding itself, so here the bare " <>
             "command really is the whole fix and naming --id would send the " <>
             "reader hunting a value they do not need"
  end

  # CodeMySpec's task mints against the server, so for a copy there the bare
  # command *is* sufficient. The right advice depends on who is asking, which is
  # why it is an option rather than something this module can know.
  test "a caller that can mint supplies its own remedy" do
    put_settings(%{})

    assert %{remedy: "mix cms.harness.onboard"} =
             Onboarding.check(@root, io: FakeIO, remedy: "mix cms.harness.onboard")
  end
end
