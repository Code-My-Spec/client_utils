defmodule ClientUtils.WidgetAuth do
  @moduledoc "Owner-approved, project-scoped installation credentials. Never exposed to visitors."
  alias ClientUtils.Widget
  @device_grant "urn:ietf:params:oauth:grant-type:device_code"

  def begin_authorization(server, project_id) do
    with {:ok, client} <-
           request(server, "/oauth/register", %{
             client_name: "Support widget",
             redirect_uris: [],
             grant_types: [@device_grant]
           }),
         {:ok, grant} <-
           request(server, "/oauth/device/code", %{
             client_id: client["client_id"],
             widget_project_id: project_id
           }) do
      {:ok,
       Map.merge(grant, %{
         "client_id" => client["client_id"],
         "server" => server,
         "project_id" => project_id
       })}
    end
  end

  def poll(grant, path) do
    with {:ok, token} <-
           request(grant["server"], "/oauth/token", %{
             grant_type: @device_grant,
             client_id: grant["client_id"],
             device_code: grant["device_code"]
           }),
         "widget" <- token["scope"],
         refresh when is_binary(refresh) and refresh != "" <- token["refresh_token"],
         :ok <-
           persist(
             path,
             Map.take(grant, ["client_id", "server", "project_id"])
             |> Map.put("refresh_token", refresh)
           ) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_response}
    end
  end

  def socket_token(user_id, email) do
    with path when is_binary(path) and path != "" <-
           Widget.config(:codemyspec_widget_credentials_path),
         {:ok, content} <- File.read(path),
         {:ok, %{"server" => server, "client_id" => client, "refresh_token" => refresh}} <-
           Jason.decode(content),
         true <- server == server_url(),
         {:ok, %{"access_token" => access}} <-
           request(server, "/api/widget/installation/token", %{
             client_id: client,
             refresh_token: refresh
           }),
         {:ok, %{"socket_token" => token}} <-
           request(
             server,
             "/api/widget/installation/socket_token",
             %{user_id: user_id, user_email: email},
             [{"authorization", "Bearer " <> access}]
           ) do
      {:ok, token}
    else
      _ -> {:error, :authorization_required}
    end
  end

  def server_url do
    case Widget.config(:codemyspec_widget_url) do
      value when is_binary(value) ->
        uri = URI.parse(value)

        URI.to_string(%{
          uri
          | scheme: if(uri.scheme == "wss", do: "https", else: "http"),
            path: nil,
            query: nil,
            fragment: nil
        })

      _ ->
        nil
    end
  end

  defp request(server, path, body, headers \\ []) do
    case Req.post(
           url: String.trim_trailing(server, "/") <> path,
           json: body,
           headers: headers,
           retry: false,
           redirect: false,
           receive_timeout: 15_000
         ) do
      {:ok, %{status: status, body: body}} when status in [200, 201] and is_map(body) ->
        {:ok, body}

      {:ok, %{body: %{"error" => error}}} ->
        {:error, error}

      _ ->
        {:error, :unreachable}
    end
  end

  defp persist(path, data) do
    temporary = path <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, file} <- File.open(temporary, [:write, :exclusive, :binary]) do
      try do
        with :ok <- File.chmod(temporary, 0o600),
             :ok <- IO.binwrite(file, Jason.encode!(data)),
             :ok <- :file.sync(file),
             :ok <- File.close(file),
             :ok <- File.rename(temporary, path),
             do: :ok
      after
        File.close(file)
        File.rm(temporary)
      end
    end
  end
end
