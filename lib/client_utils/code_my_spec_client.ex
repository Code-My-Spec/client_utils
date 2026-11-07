defmodule ClientUtils.CodeMySpecClient do
  @moduledoc "Owner-approved, project-scoped installation credentials. Never exposed to visitors."
  @device_grant "urn:ietf:params:oauth:grant-type:device_code"

  @doc "Build a client from the host application's CodeMySpec configuration."
  def new(otp_app) do
    %{
      server_url: Application.get_env(otp_app, :codemyspec_server_url),
      credentials_path: Application.get_env(otp_app, :codemyspec_credentials_path)
    }
  end

  def begin_authorization(server, project_id, scopes \\ ["widget", "users"]) do
    with {:ok, client} <-
           http_request(server, :post, "/oauth/register", %{
             client_name: "CodeMySpec application",
             redirect_uris: [],
             grant_types: [@device_grant]
           }),
         {:ok, grant} <-
           http_request(server, :post, "/oauth/device/code", %{
             client_id: client["client_id"],
             project_id: project_id,
             scope: Enum.join(scopes, " ")
           }) do
      {:ok,
       Map.merge(grant, %{
         "client_id" => client["client_id"],
         "server" => server,
         "project_id" => project_id,
         "scope" => Enum.join(scopes, " ")
       })}
    end
  end

  def poll(grant, path) do
    with {:ok, token} <-
           http_request(grant["server"], :post, "/oauth/token", %{
             grant_type: @device_grant,
             client_id: grant["client_id"],
             device_code: grant["device_code"]
           }),
         true <- token["scope"] == grant["scope"],
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

  @doc "Mint a short-lived socket credential for a host-authenticated visitor."
  def widget_socket_token(client, user_id, email) do
    with {:ok, %{"socket_token" => token}} <-
           request(client, :post, "/api/client/widget/socket_token", %{
             user_id: user_id,
             user_email: email
           }),
         do: {:ok, token}
  end

  @doc "Create or update an end user on this installation's approved project."
  def upsert_user(client, user), do: request(client, :post, "/api/client/users", %{user: user})

  @doc "Make a project-authenticated request; credentials stay on this host."
  def request(client, method, route, body \\ %{})

  def request(%{server_url: server, credentials_path: path}, method, "/" <> _ = route, body)
      when is_binary(server) and is_binary(path) do
    with {:ok, %{"client_id" => id, "refresh_token" => refresh}} <- credentials(path, server),
         {:ok, %{"access_token" => access}} <-
           http_request(server, :post, "/api/client/token", %{
             client_id: id,
             refresh_token: refresh
           }) do
      http_request(server, method, route, body, [{"authorization", "Bearer " <> access}])
    else
      {:error, _} = error -> error
      _ -> {:error, :authorization_required}
    end
  end

  def request(_, _, _, _), do: {:error, :not_configured}

  defp credentials(path, server) do
    with {:ok, content} <- File.read(path),
         {:ok, %{"server" => ^server, "client_id" => id, "refresh_token" => refresh} = data} <-
           Jason.decode(content),
         true <- is_binary(id) and is_binary(refresh) and refresh != "" do
      {:ok, data}
    else
      _ -> {:error, :authorization_required}
    end
  end

  defp http_request(server, method, path, body, headers \\ []) do
    case Req.request(
           method: method,
           url: String.trim_trailing(server, "/") <> path,
           json: body,
           headers: headers,
           retry: false,
           redirect: false,
           receive_timeout: 15_000
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{body: %{"error" => error}}} ->
        {:error, error}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      _ ->
        {:error, :unreachable}
    end
  rescue
    _ -> {:error, :unreachable}
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
