defmodule ClientUtils.WidgetTest do
  use ExUnit.Case, async: false
  alias ClientUtils.{SupportWidgetLive, Widget, WidgetVerifyController}

  test "anonymous mounts without a session identifier never share an identity" do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
    {:ok, first, _} = SupportWidgetLive.mount(%{}, %{}, socket)
    {:ok, second, _} = SupportWidgetLive.mount(%{}, %{}, socket)
    refute first.assigns.identity.id == second.assigns.identity.id
  end

  test "browser parameters do not replace the authenticated host identity" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, current_scope: %{user: %{id: 1, email: "real@example.com"}}}
    }

    {:ok, mounted, _} =
      SupportWidgetLive.mount(
        %{"user_id" => "victim", "user_email" => "victim@example.com"},
        %{},
        socket
      )

    assert mounted.assigns.identity == %{id: "1", email: "real@example.com"}
  end

  test "missing configuration degrades gracefully and never authenticates verification" do
    start_supervised!({Widget, otp_app: :widget_unconfigured_test})
    assert {:error, :not_configured} = Widget.ensure_started("one", "one@example.com")
    assert Widget.state("one") == %{messages: [], connected: false}
    conn = Plug.Test.conn(:post, "/_cms/verify/widget") |> WidgetVerifyController.create(%{})
    assert conn.status == 401
  end
end
