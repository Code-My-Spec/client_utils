defmodule ClientUtils.Harness.PreviewTest do
  @moduledoc """
  Story 968. Onboarding asks the server where this copy's preview answers.

  The interesting behaviour is not the happy path — it is that nothing here can
  stop onboarding. A checkout that is not the project's main one, a server with
  no Cloudflare account, a laptop onboarding on a train: all of them return
  `:none` and the run continues, because a copy that came back with its
  identity, databases, hooks and proxy configured but no preview is far more
  useful than a copy whose onboarding aborted over one.

  The worktree case is not an edge case. Most checkouts are worktrees, so the
  409 branch runs more often than the success branch does.
  """

  use ExUnit.Case, async: true

  alias ClientUtils.Harness.Preview

  @id "aa11bb22-0000-4000-8000-000000000968"
  @key "deploy-key-for-968"

  # Req's `adapter:` rather than `plug:`. The plug route needs `:plug` on the
  # dependency list, and this library is a dependency of every generated
  # application — a test-only dep is still a dep somebody has to resolve.
  defp answering(status, body) do
    [
      req_options: [
        adapter: fn request ->
          {request, %Req.Response{status: status, body: body}}
        end
      ]
    ]
  end

  describe "when the server answers" do
    test "the address and the tunnel come back under the keys the config holds" do
      assert {:ok, preview} =
               Preview.ensure(
                 "https://codemyspec.test",
                 @id,
                 @key,
                 answering(200, %{
                   "preview_url" => "https://preview-#{@id}.codemyspec.com",
                   "tunnel_id" => "tunnel-1",
                   "tunnel_secret" => "c2VjcmV0",
                   "account_tag" => "acct-1",
                   "embedder" => "https://codemyspec.test"
                 })
               )

      assert preview["preview_url"] == "https://preview-#{@id}.codemyspec.com"
      assert preview["preview_tunnel_id"] == "tunnel-1"
      assert preview["preview_tunnel_secret"] == "c2VjcmV0"

      assert preview["preview_embedder"] == "https://codemyspec.test",
             "the server says who may frame this app; an app left to guess can " <>
               "guess wrong, and wrong here refuses the pane silently"

      assert preview["preview_account_tag"] == "acct-1",
             "cloudflared's credentials file names the account, so a copy without it " <>
               "holds a tunnel it cannot run"
    end
  end

  describe "when there is nothing to ask with" do
    test "a copy that has not been issued an id asks nothing" do
      assert :none = Preview.ensure("https://codemyspec.test", nil, @key)
    end

    test "a copy with no deploy key asks nothing" do
      assert :none = Preview.ensure("https://codemyspec.test", @id, nil)
    end

    test "no server configured asks nothing" do
      assert :none = Preview.ensure(nil, @id, @key)
    end
  end

  describe "when the server refuses" do
    test "a worktree is told no and onboarding carries on" do
      assert :none =
               Preview.ensure(
                 "https://codemyspec.test",
                 @id,
                 @key,
                 answering(409, %{"error" => "not_the_main_copy"})
               )
    end

    test "a server with no Cloudflare account configured does not stop the run" do
      assert :none =
               Preview.ensure(
                 "https://codemyspec.test",
                 @id,
                 @key,
                 answering(503, %{"error" => "previews_not_configured"})
               )
    end

    test "an unreachable server does not stop the run" do
      assert :none =
               Preview.ensure("https://codemyspec.test", @id, @key,
                 req_options: [
                   adapter: fn request ->
                     {request, %Req.TransportError{reason: :econnrefused}}
                   end
                 ]
               )
    end
  end
end
