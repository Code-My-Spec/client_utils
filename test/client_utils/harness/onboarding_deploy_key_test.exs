defmodule ClientUtils.Harness.Onboarding.DeployKeyTest do
  @moduledoc """
  A working copy carries the deploy key its harness is served with.

  A deploy key reaches exactly one project — deliberately, so a harness on one
  project does not inherit everything its owner can do — while one harness serves
  every checkout it has a subtree for. A daemon holding a single key from its
  environment can therefore only join one project.

  Measured 2026-08-21 on a machine serving three copies: a checkout of a second
  project connected its socket and had every join refused, every thirty seconds
  for hours, with every hook in it answering "channel down, server answering
  200" while the harness's own `/health` said connected — because that is about
  the socket, not the channel.

  So the key goes in `.cms_harness.json`, beside the identity it authenticates
  and where the harness already walks up to find it. Git ignores that file, and
  the real-filesystem adapter restricts it.

  What these pin is the pair of rules that make it safe to write there: a run
  with a key records it, and a run without one never blanks the key a previous
  run wrote — the same rule this module already applies to the address, and for
  the same reason.
  """

  use ExUnit.Case, async: true

  alias ClientUtils.Harness.Onboarding

  @root "/workspace/app"
  @harness "d1c8f8f5-1111-2222-3333-444455556666"
  @key "03ee0248c7deadbeef"

  defmodule FakeIO do
    @moduledoc false
    @behaviour ClientUtils.Harness.Onboarding.IO

    @impl true
    def read_file(_root, path) do
      case Process.get({:file, path}) do
        nil -> {:error, :enoent}
        contents -> {:ok, contents}
      end
    end

    @impl true
    def file_exists?(_root, path), do: Process.get({:file, path}) != nil

    @impl true
    def write_file(_root, path, contents) do
      Process.put({:file, path}, contents)
      :ok
    end

    # Recorded rather than performed: this adapter has no inode. The point is
    # that `onboard/2` asks, so the real adapter — which does — is asked too.
    def chmod(_root, path, mode) do
      Process.put({:chmod, path}, mode)
      :ok
    end

    @impl true
    def cmd(_root, _command, _args, _opts \\ []), do: {"", 0}
  end

  defp onboard(opts) do
    Onboarding.onboard(@root, Keyword.merge([io: FakeIO, app: :app, harness_id: @harness], opts))
  end

  defp harness_config do
    Process.get({:file, Onboarding.harness_config_path()}) |> Jason.decode!()
  end

  test "a key given is recorded against this copy" do
    onboard(deploy_key: @key)

    assert harness_config()["deploy_key"] == @key
  end

  test "it lands beside the identity it authenticates, not in a file of its own" do
    onboard(deploy_key: @key)

    config = harness_config()

    assert config["harness_id"] == @harness
    assert config["root"] == @root

    assert config["deploy_key"] == @key,
           "one file per working copy answers 'what is this checkout' — a second " <>
             "store would be a second thing to keep in step with it"
  end

  # The rule that makes it safe for CodeMySpec's own task to call this: that task
  # writes the id and the project and knows nothing about the key, so a run that
  # blanked it would destroy the credential on every re-onboard.
  test "a run with no key keeps the one already recorded" do
    onboard(deploy_key: @key)
    onboard([])

    assert harness_config()["deploy_key"] == @key
  end

  test "and a copy that never had one does not gain a blank" do
    onboard([])

    refute Map.has_key?(harness_config(), "deploy_key"),
           "a null here reads as 'recorded, and empty', which is a different and " <>
             "worse claim than 'not recorded'"
  end

  # Asked on every run, not only when a key was passed: a copy that recorded one
  # on an earlier run still has a secret in the file.
  test "the file is restricted, whether or not this run supplied the key" do
    onboard(deploy_key: @key)
    assert Process.get({:chmod, Onboarding.harness_config_path()}) == 0o600

    Process.delete({:chmod, Onboarding.harness_config_path()})
    onboard([])
    assert Process.get({:chmod, Onboarding.harness_config_path()}) == 0o600
  end

  # `chmod/3` is optional on the port. A host writing through a channel to
  # another machine, and an in-memory adapter, have no local inode — and
  # onboarding must not fail because one of them cannot restrict a file.
  test "an adapter without chmod still onboards" do
    defmodule NoChmodIO do
      @moduledoc false
      @behaviour ClientUtils.Harness.Onboarding.IO

      @impl true
      def read_file(_root, _path), do: {:error, :enoent}
      @impl true
      def file_exists?(_root, _path), do: false
      @impl true
      def write_file(_root, _path, _contents), do: :ok
      @impl true
      def cmd(_root, _command, _args, _opts \\ []), do: {"", 0}
    end

    report =
      Onboarding.onboard(@root,
        io: NoChmodIO,
        app: :app,
        harness_id: @harness,
        deploy_key: @key
      )

    assert {:ok, _path} = report.hooks
  end
end
