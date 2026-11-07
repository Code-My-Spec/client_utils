defmodule ClientUtils.CodeMySpecClientTest do
  use ExUnit.Case, async: true
  alias ClientUtils.CodeMySpecClient

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
