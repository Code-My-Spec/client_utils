defmodule ClientUtils.Harness.Onboarding.ServerUrlTest do
  @moduledoc """
  A working copy records which CodeMySpec issued its harness id.

  An id means nothing to a server that did not mint it, and nothing else can say
  which one did: every way of resolving "the server" answers with the build
  doing the *reading*. So a copy onboarded by one build and served by another —
  a sibling repo onboarded from a dev checkout, a generated app onboarded by its
  own release — had no way to name where it belonged, and every hook in it came
  back "No harness with id …". That reads like a deleted row, and it is two
  servers that never shared one.

  Distinct from `base_url:`, which is the *harness* this copy's hooks post to.
  This is the CodeMySpec the harness itself talks to, and conflating them is why
  the value could not simply be inferred from what was already here.

  Same two rules as the deploy key beside it: a run that knows records it, and a
  run that does not never blanks what a previous run wrote — CodeMySpec's own
  task calls this without always knowing, and a blanking run would erase the
  answer on every re-onboard.
  """

  use ExUnit.Case, async: true

  alias ClientUtils.Harness.Onboarding

  @root "/workspace/app"
  @harness "d1c8f8f5-1111-2222-3333-444455556666"
  @server "https://codemyspec.com"

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

  test "a server given is recorded against this copy" do
    onboard(server_url: @server)

    assert harness_config()["server_url"] == @server
  end

  test "it lands beside the id it makes meaningful" do
    onboard(server_url: @server)

    config = harness_config()

    assert config["harness_id"] == @harness
    assert config["server_url"] == @server,
           "the id and the server that issued it are one fact. Recorded apart, a " <>
             "reader has an id and no way to tell who will recognise it"
  end

  test "a run with no server keeps the one already recorded" do
    onboard(server_url: @server)
    onboard([])

    assert harness_config()["server_url"] == @server,
           "re-onboarding a copy must not cost it the answer it already had — " <>
             "CodeMySpec's own task calls this without always knowing the server"
  end

  test "and a copy that never had one does not gain a blank" do
    onboard([])

    refute Map.has_key?(harness_config(), "server_url"),
           "a null here reads as 'recorded, and empty', which is a different and " <>
             "worse claim than 'not recorded' — the caller's own default is the " <>
             "right answer for a copy that has never been told"
  end

  # The two are separate opts because they are separate machines: hooks go to a
  # harness on localhost, and the harness goes to a CodeMySpec that is usually
  # not local at all. `base_url` defaulting to localhost:4004 is exactly why the
  # server could not be read off it.
  test "the harness address and the server are not the same value" do
    onboard(base_url: "http://localhost:4004", server_url: @server)

    assert harness_config()["server_url"] == @server
  end
end
