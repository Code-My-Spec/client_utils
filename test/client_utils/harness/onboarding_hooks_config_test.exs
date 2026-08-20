defmodule ClientUtils.Harness.Onboarding.HooksConfigTest do
  @moduledoc """
  `onboard/2` must address hooks, not just MCP.

  `CMS_HARNESS_ID` in `.claude/settings.local.json` only reaches MCP — Claude
  Code interpolates `${CMS_HARNESS_ID}` into the request header itself. Hooks
  run through a separate Go relay that never sees that interpolation; it
  resolves identity by walking up from the hook payload's `cwd` looking for
  `.cms_harness.json`'s `harness_id` key. Before this, `onboard/2` never wrote
  that file at all — a working copy onboarded with `--id` had working MCP and
  silently unaddressed hooks, with nothing but a server-side refusal to say so.
  This pins that a real id produces both files, that no id produces neither,
  and that a bare re-run cannot erase a hooks address a real run already wrote.
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

  defp written_hooks_config do
    case FakeIO.read_file(@root, Onboarding.harness_config_path()) do
      {:ok, contents} -> Jason.decode!(contents)
      {:error, :enoent} -> nil
    end
  end

  test "no id writes no hooks config at all" do
    onboard()

    assert written_hooks_config() == nil
  end

  test "a real id writes a hooks config the relay can resolve" do
    onboard(harness_id: @harness)

    assert written_hooks_config() == %{
             "harness_id" => @harness,
             "project_id" => nil,
             "root" => @root
           }
  end

  test "re-running with no id does not erase a hooks address a prior run wrote" do
    onboard(harness_id: @harness)
    onboard()

    assert written_hooks_config()["harness_id"] == @harness
  end

  test "check reports HARNESS_CONFIG missing when only settings.local.json is addressed" do
    onboard(harness_id: @harness)
    Process.delete({:settings, Onboarding.harness_config_path()})

    assert %{onboarded: false, missing: missing} = Onboarding.check(@root, io: FakeIO)
    assert "HARNESS_CONFIG" in missing
  end

  test "check reports onboarded once both settings and hooks config are addressed" do
    onboard(harness_id: @harness)

    assert %{onboarded: true, missing: []} = Onboarding.check(@root, io: FakeIO)
  end

  test "the report names where hooks config was written" do
    report = onboard(harness_id: @harness)

    assert report.hooks == {:ok, Onboarding.harness_config_path()}
  end

  test "the report says hooks are skipped, not written, with no id" do
    report = onboard()

    assert report.hooks == {:ok, :skipped}
  end

  # This file is not only ours. A host writes it too — CodeMySpec's task writes
  # it first, with the project id it just resolved — and this used to stamp
  # `"project_id" => nil` over that on the next line. Measured on a real working
  # copy before the fix: `project_id` went from the real id to `null` in one run.
  #
  # It got there by going through the port, which walks past the host's own
  # `HarnessConfig.write/2` and its refusal to overwrite an existing config. A
  # guard only guards the door it is on, so the rule this module already applies
  # to `settings.local.json` — merged, never stamped — has to apply here too.
  test "keys this run has no answer for are kept, not blanked" do
    Process.put(
      {:settings, Onboarding.harness_config_path()},
      Jason.encode!(%{
        "harness_id" => "an-older-id",
        "project_id" => "708492f9-454e-482f-a2eb-be64f0356b87",
        "root" => @root,
        "something_a_host_added" => "kept"
      })
    )

    onboard(harness_id: @harness)

    config = written_hooks_config()

    assert config["harness_id"] == @harness,
           "the id this run has is the one it writes"

    assert config["project_id"] == "708492f9-454e-482f-a2eb-be64f0356b87",
           "onboarding has no project id to give and must not erase the one that is there"

    assert config["something_a_host_added"] == "kept"
  end

  test "a first write still records project_id, so the key exists to be filled" do
    onboard(harness_id: @harness)

    assert Map.has_key?(written_hooks_config(), "project_id")
  end
end
