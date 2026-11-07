defmodule Mix.Tasks.ClientUtils.Authorize do
  use Mix.Task
  @shortdoc "Authorize this host's CodeMySpec client through device flow"

  def run(args) do
    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [server: :string, project: :string, credentials: :string, scope: :string]
      )

    if invalid != [] or Enum.any?([:server, :project, :credentials], &is_nil(opts[&1])),
      do: Mix.raise("Use --server URL --project PROJECT_ID --credentials PRIVATE_FILE")

    Mix.Task.run("app.config")
    Application.ensure_all_started(:req)
    server = String.trim_trailing(opts[:server], "/")
    uri = URI.parse(server)

    unless uri.scheme == "https" or
             (uri.scheme == "http" and uri.host in ["localhost", "127.0.0.1"]),
           do:
             Mix.raise(
               "Use HTTPS for installation authorization (HTTP is allowed only on localhost)"
             )

    case ClientUtils.CodeMySpecClient.begin_authorization(
           server,
           opts[:project],
           String.split(opts[:scope] || "widget users")
         ) do
      {:ok, grant} ->
        Mix.shell().info(
          "Open #{grant["verification_uri"]} and approve code #{grant["user_code"]} as the project owner."
        )

        deadline = System.monotonic_time(:second) + grant["expires_in"]
        poll(grant, Path.expand(opts[:credentials]), deadline, grant["interval"])

      {:error, reason} ->
        Mix.raise("Authorization could not start: #{inspect(reason)}")
    end
  end

  defp poll(grant, path, deadline, interval) do
    if System.monotonic_time(:second) >= deadline,
      do: Mix.raise("Authorization expired; run again")

    Process.sleep(interval * 1000)

    case ClientUtils.CodeMySpecClient.poll(grant, path) do
      :ok ->
        Mix.shell().info(
          "CodeMySpec client authorized. Set CODEMYSPEC_CREDENTIALS_PATH to #{path} on this host."
        )

      {:error, "authorization_pending"} ->
        poll(grant, path, deadline, interval)

      {:error, "slow_down"} ->
        poll(grant, path, deadline, interval + 5)

      {:error, reason} ->
        Mix.raise("Authorization failed: #{inspect(reason)}")
    end
  end
end
