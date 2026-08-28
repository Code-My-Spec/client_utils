defmodule ClientUtils.Harness.Onboarding.PreviewKeyTest do
  @moduledoc """
  Asking for a preview uses the key the copy already recorded.

  `Preview.ensure/4` needs a server url AND a deploy key, and answers `:none` if
  either is missing — the same answer a worktree gets, which is legitimate and
  therefore silent. `--deploy-key` is documented as optional and as never
  blanking a key already on disk, so omitting it on a re-run is the normal
  thing to do. Doing the normal thing meant no preview was ever requested.

  Measured 2026-08-28: four `mix harness.onboard` runs against one checkout,
  each reporting success and writing no preview keys. Two of us diagnosed it
  wrongly first — a config merge that drops keys, then a stale harness build —
  because a request that is never sent leaves no trace to contradict either
  theory. Passing `--server-url` fixed one of the two missing arguments and
  changed nothing, which read as evidence for the wrong hypotheses.

  So: the key comes off disk when the run was not handed one, and a run that
  asks for nothing says why.
  """

  use ExUnit.Case, async: true

  alias ClientUtils.Harness.Onboarding

  @root "/workspace/app"
  @harness "d1c8f8f5-1111-2222-3333-444455556666"
  @key "dk_recorded_earlier"

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

    def chmod(_root, _path, _mode), do: :ok

    @impl true
    def cmd(_root, _command, _args, _opts \\ []), do: {"", 0}
  end

  defp onboard(opts) do
    Onboarding.onboard(@root, Keyword.merge([io: FakeIO, app: :app, harness_id: @harness], opts))
  end

  describe "a run given no deploy key" do
    test "asks with the one already on disk" do
      # A first run records the key, the way the real first onboarding does.
      onboard(deploy_key: @key)

      test_pid = self()

      # The second run passes no key. It must still ask.
      report =
        onboard(
          server_url: "http://localhost:4000",
          req_options: [
            plug: fn conn ->
              send(test_pid, {:asked, Plug.Conn.get_req_header(conn, "authorization")})

              conn
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.resp(
                200,
                Jason.encode!(%{
                  "preview_url" => "https://preview-x.codemyspec.com",
                  "tunnel_id" => "t-1",
                  "tunnel_secret" => "s-1",
                  "account_tag" => "acct",
                  "embedder" => "https://dev.codemyspec.com"
                })
              )
            end
          ]
        )

      assert_received {:asked, ["Bearer " <> sent]},
                      "no request was made at all, so the preview was skipped over a " <>
                        "key that was sitting in the file the whole time"

      assert sent == @key
      assert report.preview == %{address: "https://preview-x.codemyspec.com"}
    end
  end

  describe "a run that asks for nothing" do
    test "says it had no server" do
      report = onboard(deploy_key: @key)

      assert %{skipped: reason} = report.preview

      assert reason =~ "server",
             "the report is silent about why there is no address. Four runs said " <>
               "nothing and cost a night; a skip is a fine outcome and an " <>
               "unexplained one is not. Got: #{inspect(report.preview)}"
    end

    test "says it had no key" do
      report = onboard(server_url: "http://localhost:4000")

      assert %{skipped: reason} = report.preview
      assert reason =~ "deploy key", "got: #{inspect(report.preview)}"
    end
  end
end
