defmodule ClientUtils.Harness.Preview do
  @moduledoc """
  Where this working copy's preview answers, asked of the server that can say.

  Story 968. A project's preview runs from its main checkout, and the address it
  answers on has to exist before anybody looks for it — the whole point is that
  it appears without being found or configured.

  ## Why this asks instead of provisioning

  The address is reached over a named Cloudflare tunnel on CodeMySpec's own
  zone, and creating one needs CodeMySpec's Cloudflare credential. That
  credential cannot ship here: this library is a dependency of every generated
  application, so a credential in it is a credential every customer holds, on a
  zone none of them own.

  The server already has it. So this sends the working copy's id and its deploy
  key and takes back an address plus what `ClientUtils.CloudflareTunnel` needs to
  run the tunnel in named mode. The keys come back named exactly as that module's
  options, deliberately — a translation step between the two is somewhere for
  them to drift apart.

  ## Every refusal is `:none`, and that is not laziness

  Onboarding does a dozen things and a preview is one of them. A copy that comes
  back with its identity, its databases, its hooks and its proxy configured but
  no preview is far more useful than a copy whose onboarding aborted — and the
  reasons it can be refused are all ordinary:

    * this checkout is not the project's main one (409), which is true of every
      worktree and most of them by design
    * the server has no Cloudflare account configured (503), which is an
      operator's problem and not this checkout's
    * the server is not reachable at all, which is the normal state of a laptop
      onboarding offline

  None of those mean the checkout is broken, so none of them stop the run. The
  caller reports what happened and moves on.
  """

  require Logger

  @doc """
  Ask for this copy's preview.

  `{:ok, map}` carries `preview_url`, `preview_tunnel_id` and
  `preview_tunnel_secret` — the keys `.cms_harness.json` holds — plus
  `account_tag` for the tunnel's credentials file.

  `:none` for every refusal, reachable or not. See the moduledoc: none of them
  is a reason to stop onboarding.
  """
  @spec ensure(String.t() | nil, String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, map()} | :none
  def ensure(server_url, working_copy_id, deploy_key, opts \\ [])

  def ensure(server_url, working_copy_id, deploy_key, opts)
      when is_binary(server_url) and is_binary(working_copy_id) and is_binary(deploy_key) and
             server_url != "" and working_copy_id != "" and deploy_key != "" do
    url =
      server_url
      |> String.trim_trailing("/")
      |> Kernel.<>("/api/harnesses/#{working_copy_id}/preview")

    [
      url: url,
      headers: [{"authorization", "Bearer " <> deploy_key}],
      json: %{},
      retry: false,
      receive_timeout: to_timeout(second: 30)
    ]
    |> Keyword.merge(Keyword.get(opts, :req_options, []))
    |> Req.post()
    |> interpret()
  end

  # Missing any of the three is the ordinary case rather than a mistake: a copy
  # with no id has not been issued one yet, and a copy with no deploy key is
  # served by a daemon holding the project's key in its environment.
  def ensure(_server_url, _working_copy_id, _deploy_key, _opts), do: :none

  defp interpret({:ok, %{status: 200, body: %{} = body}}) do
    {:ok,
     %{
       "preview_url" => body["preview_url"],
       "preview_tunnel_id" => body["tunnel_id"],
       "preview_tunnel_secret" => body["tunnel_secret"],
       "account_tag" => body["account_tag"]
     }}
  end

  # Said at info rather than warning. Every worktree of every project takes this
  # branch, which is the design — a warning per worktree per onboarding would
  # train the reader past the channel entirely.
  defp interpret({:ok, %{status: 409}}) do
    Logger.info("[ClientUtils] no preview for this checkout: it is not the project's main one")
    :none
  end

  defp interpret({:ok, %{status: 503, body: body}}) do
    Logger.warning("[ClientUtils] the server cannot make previews: #{detail(body)}")
    :none
  end

  defp interpret({:ok, %{status: status, body: body}}) do
    Logger.warning("[ClientUtils] could not get a preview address (#{status}): #{detail(body)}")
    :none
  end

  defp interpret({:error, reason}) do
    Logger.info("[ClientUtils] could not reach the server for a preview: #{inspect(reason)}")
    :none
  end

  defp detail(%{"detail" => detail}) when is_binary(detail), do: detail
  defp detail(%{"error" => error}) when is_binary(error), do: error
  defp detail(body), do: inspect(body)
end
