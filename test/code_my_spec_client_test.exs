defmodule ClientUtils.CodeMySpecClientTest do
  use ExUnit.Case, async: false
  alias ClientUtils.CodeMySpecClient

  test "authorization defaults to widget and users requires an explicit request" do
    previous = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    on_exit(fn -> Req.default_options(previous) end)
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
      send(owner, {:authorization_request, conn.request_path, conn.body_params})

      Req.Test.json(conn, %{
        client_id: "client",
        client_secret: "backend-only",
        device_code: "device"
      })
    end)

    server = "https://example.com"

    assert {:ok, grant} = CodeMySpecClient.begin_authorization(server, "project")
    assert grant["scope"] == "widget"
    assert_receive {:authorization_request, "/oauth/register", %{"scope" => "widget"}}
    assert_receive {:authorization_request, "/oauth/device/code", %{"scope" => "widget"}}

    assert {:ok, grant} =
             CodeMySpecClient.begin_authorization(server, "project", ["widget", "users"])

    assert grant["scope"] == "widget users"
    assert_receive {:authorization_request, "/oauth/register", %{"scope" => "widget users"}}
    assert_receive {:authorization_request, "/oauth/device/code", %{"scope" => "widget users"}}
  end

  test "an unconfigured client does not require the widget supervisor" do
    client = CodeMySpecClient.new(:unconfigured_client_test)

    assert {:error, :not_configured} =
             CodeMySpecClient.upsert_user(client, %{email: "a@example.com"})
  end

  test "malformed credential files return a safe error without their contents" do
    path =
      Path.join(System.tmp_dir!(), "bad-cms-credentials-#{System.unique_integer([:positive])}")

    File.write!(path, ~s({"refresh_token":"never-return-this-secret"))
    on_exit(fn -> File.rm(path) end)
    client = %{server_url: "https://example.com", credentials_path: path}
    assert {:error, :authorization_required} = CodeMySpecClient.upsert_user(client, %{})
  end
end
