defmodule ClientUtils.WidgetTest do
  use ExUnit.Case, async: false
  alias ClientUtils.{SupportWidgetLive, Widget, WidgetVerifyController}

  test "widget supervision starts only with a URL and credential path" do
    app = :widget_startup_test

    on_exit(fn ->
      Application.delete_env(app, :codemyspec_server_url)
      Application.delete_env(app, :codemyspec_credentials_path)
    end)

    assert :ignore = Widget.start_link(otp_app: app)
    Application.put_env(app, :codemyspec_server_url, "https://example.com")
    assert :ignore = Widget.start_link(otp_app: app)
    Application.put_env(app, :codemyspec_credentials_path, "/private/widget.json")
    assert Widget.configured?(app)
    assert is_pid(start_supervised!({Widget, otp_app: app}))
  end

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
    assert :ignore = Widget.start_link(otp_app: :widget_unconfigured_test)
    refute Process.whereis(ClientUtils.WidgetSupervisor)
    assert {:error, :not_configured} = Widget.ensure_started("one", "one@example.com")
    conn = Plug.Test.conn(:post, "/_cms/verify/widget") |> WidgetVerifyController.create(%{})
    assert conn.status == 401
  end
end
