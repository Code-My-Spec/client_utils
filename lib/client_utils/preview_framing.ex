defmodule ClientUtils.PreviewFraming do
  @moduledoc """
  Lets the CodeMySpec preview pane embed this application, and nothing else.

  Phoenix's `put_secure_browser_headers/1` sends
  `content-security-policy: base-uri 'self'; frame-ancestors 'self';`. That is
  the right default and it refuses the preview: a pane on `codemyspec.com`
  framing an app on its own preview host is a different origin, so the browser
  declines to render it.

  The refusal is silent. No request fails, no log line appears, and the iframe
  element looks perfectly healthy while showing nothing — which reads to the
  person watching as *their app* being broken. That failure mode is the whole
  reason this exists rather than being left to whoever notices.

  ## Why the application says this rather than a proxy

  It used to be a proxy. Every preview request went through CodeMySpec, which
  rewrote the header on the way back. That works only while the app is somewhere
  CodeMySpec can dial, and the preview now reaches applications over a tunnel
  they open themselves — a laptop behind a router, a container, a machine on a
  network nobody here has heard of. Nothing sits in that path any more.

  Which is the better arrangement anyway: the application knows whether it is
  meant to be embedded. A proxy could only assert it on the app's behalf.

  ## Nothing is widened until there is a preview

  With no preview configured this is a no-op and `'self'` stands. An application
  that is not being previewed gains no new embedder, so adding the plug to a
  pipeline is not itself a loosening — the loosening happens when onboarding
  records a preview, and lasts only as long as one is configured.

  ## Use

      plug ClientUtils.PreviewFraming, otp_app: :my_app

  In the `:browser` pipeline, *after* `:put_secure_browser_headers` — it
  replaces that header's value, so running first would have the default write
  over it.

  `otp_app:` is how it finds the preview: the address lives in the consuming
  application's own `:preview` config, not in this library's. Without it the
  plug is a no-op, which is the right failure — a library that guessed would
  answer the same thing for every application in the release.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    case embedder(opts) do
      nil -> conn
      origin -> allow(conn, origin)
    end
  end

  # Registered rather than set directly, because the header is written *after*
  # this plug runs — `put_secure_browser_headers/1` is a plug too, and whichever
  # of the two runs last wins. Registering a callback means this applies to the
  # response as it goes out, whatever wrote the header on the way.
  defp allow(conn, origin) do
    Plug.Conn.register_before_send(conn, fn conn ->
      conn
      # No syntax for "this one origin" — any value at all refuses the frame, so
      # it is dropped rather than rewritten. `frame-ancestors` below says the
      # same thing precisely, and every browser that matters prefers it.
      |> Plug.Conn.delete_resp_header("x-frame-options")
      |> Plug.Conn.put_resp_header(
        "content-security-policy",
        "base-uri 'self'; frame-ancestors 'self' #{origin};"
      )
    end)
  end

  # Explicit configuration first, so an application can name an embedder without
  # having been onboarded — the case a test or a self-hosted install needs.
  # Each source goes through `presence/1`, including the explicit one. Passed
  # straight through, a blank string is truthy and lands in the header as
  # `frame-ancestors 'self'   ;` — not the secured default, and a widening
  # nobody asked for wearing the costume of a no-op.
  defp embedder(opts) do
    presence(opts[:frame_ancestors]) || from_preview(opts[:otp_app])
  end

  # Out of the *application's* own `:preview` config, which is where
  # `Preview.from_checkout/2` puts it — not out of `:client_utils`. A library
  # reading its own application environment for a value that belongs to its
  # consumer would answer the same thing for every app in the release, which is
  # exactly wrong for a value that says who may frame one of them.
  #
  # So the plug is told which app it is protecting. `nil` — the plug added
  # without one — is a no-op rather than a guess.
  defp from_preview(nil), do: nil

  defp from_preview(otp_app) do
    otp_app
    |> Application.get_env(:preview, [])
    |> Keyword.get(:embedder)
    |> presence()
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end
