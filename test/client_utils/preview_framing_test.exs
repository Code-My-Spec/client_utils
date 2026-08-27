defmodule ClientUtils.PreviewFramingTest do
  @moduledoc """
  Story 968. The preview reaches the app over a tunnel now, so nothing sits in
  the path to rewrite headers — the app has to say who may embed it.

  The case that matters most is the one with no assertion about CSP at all: an
  app with no preview configured must be left exactly as Phoenix secured it.
  Adding this plug to a pipeline cannot itself be a loosening, or every
  generated application becomes embeddable the day the plug ships.
  """

  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias ClientUtils.PreviewFraming

  @secured "base-uri 'self'; frame-ancestors 'self';"
  @embedder "https://codemyspec.com"

  # What `put_secure_browser_headers/1` leaves behind, which is what this plug
  # actually has to contend with.
  defp secured_conn do
    :get
    |> conn("/")
    |> put_resp_header("content-security-policy", @secured)
    |> put_resp_header("x-frame-options", "SAMEORIGIN")
  end

  defp run(conn, opts) do
    conn |> PreviewFraming.call(PreviewFraming.init(opts)) |> send_resp(200, "")
  end

  describe "with a preview configured" do
    test "the pane may embed this app" do
      conn = run(secured_conn(), frame_ancestors: @embedder)

      assert get_resp_header(conn, "content-security-policy") == [
               "base-uri 'self'; frame-ancestors 'self' #{@embedder};"
             ]
    end

    test "x-frame-options is dropped rather than rewritten" do
      conn = run(secured_conn(), frame_ancestors: @embedder)

      assert get_resp_header(conn, "x-frame-options") == [],
             "it has no syntax for a single origin, so any value left on it refuses " <>
               "the frame no matter what frame-ancestors says"
    end

    test "the app can still embed itself" do
      conn = run(secured_conn(), frame_ancestors: @embedder)

      assert hd(get_resp_header(conn, "content-security-policy")) =~ "'self'",
             "widening for the pane must not cost the app its own frames"
    end

    test "it wins over the secure default whichever ran first" do
      # The header written *after* the plug runs, which is what happens when
      # `put_secure_browser_headers` sits later in the pipeline.
      conn =
        :get
        |> conn("/")
        |> PreviewFraming.call(PreviewFraming.init(frame_ancestors: @embedder))
        |> put_resp_header("content-security-policy", @secured)
        |> send_resp(200, "")

      assert hd(get_resp_header(conn, "content-security-policy")) =~ @embedder,
             "the plug lost to a later write, so the pane is refused depending on " <>
               "pipeline order — the worst kind of bug to diagnose from a blank frame"
    end
  end

  describe "with no preview configured" do
    test "the app is left exactly as Phoenix secured it" do
      conn = run(secured_conn(), [])

      assert get_resp_header(conn, "content-security-policy") == [@secured],
             "an app with no preview gained an embedder merely by having the plug " <>
               "in its pipeline"

      assert get_resp_header(conn, "x-frame-options") == ["SAMEORIGIN"]
    end

    test "an empty configured value is no configuration" do
      conn = run(secured_conn(), frame_ancestors: "  ")

      assert get_resp_header(conn, "content-security-policy") == [@secured]
    end
  end
end
