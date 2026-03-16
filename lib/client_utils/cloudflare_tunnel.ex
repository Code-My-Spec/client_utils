defmodule ClientUtils.CloudflareTunnel do
  @moduledoc """
  GenServer that manages a Cloudflare Tunnel process via an Erlang port.

  Supports two modes:

  ## Quick tunnel (default)

  Runs `cloudflared tunnel --url <origin>` which assigns a random
  `*.trycloudflare.com` URL — no account, credentials, or DNS required.

  The GenServer parses the tunnel URL from cloudflared's stdout and
  reconfigures the Phoenix endpoint so URL helpers generate correct
  public URLs.

      {ClientUtils.CloudflareTunnel,
        origin_url: "http://127.0.0.1:4000",
        endpoint: MyAppWeb.Endpoint,
        otp_app: :my_app}

  ## Named tunnel

  Uses a pre-configured Cloudflare named tunnel with a fixed hostname.
  Requires credentials and DNS configured in Cloudflare dashboard.

      {ClientUtils.CloudflareTunnel,
        mode: :named,
        hostname: "dev.myapp.com",
        tunnel_id: "...",
        account_tag: "...",
        tunnel_secret: "...",
        origin_url: "http://127.0.0.1:4000",
        endpoint: MyAppWeb.Endpoint,
        otp_app: :my_app}

  ## Required opts (both modes)

    * `:origin_url` — local origin URL (e.g. `"http://127.0.0.1:4000"`)
    * `:endpoint` — Phoenix Endpoint module (e.g. `MyAppWeb.Endpoint`)
    * `:otp_app` — OTP app atom (e.g. `:my_app`)

  ## Additional required opts (named mode)

    * `:hostname` — public hostname for the tunnel
    * `:tunnel_id` — Cloudflare tunnel UUID
    * `:account_tag` — Cloudflare account tag
    * `:tunnel_secret` — tunnel credential secret (base64)

  ## Optional opts

    * `:enabled` — `true` (default) or `false`; when `false`, the tunnel is not started
    * `:mode` — `:quick` (default) or `:named`
    * `:name` — GenServer name registration (default: `__MODULE__`)
  """

  use GenServer
  require Logger

  @url_regex ~r"https://[a-z0-9-]+\.trycloudflare\.com"

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the current tunnel URL, or nil if not yet established."
  def url, do: url(__MODULE__)

  @doc "Returns the current tunnel URL for the given server name."
  def url(name), do: GenServer.call(name, :url)

  @doc false
  def parse_url(line) do
    case Regex.run(@url_regex, line) do
      [url] -> url
      nil -> nil
    end
  end

  @impl true
  def init(opts) do
    if Keyword.get(opts, :enabled, true) == false do
      Logger.info("[CloudflareTunnel] Tunnel disabled via :enabled option")
      :ignore
    else
      do_init(opts)
    end
  end

  defp do_init(opts) do
    case System.find_executable("cloudflared") do
      nil ->
        Logger.warning("[CloudflareTunnel] cloudflared not found in PATH — tunnel disabled")
        :ignore

      cloudflared ->
        mode = Keyword.get(opts, :mode, :quick)
        init_mode(mode, cloudflared, opts)
    end
  end

  defp init_mode(:quick, cloudflared, opts) do
    origin_url = Keyword.fetch!(opts, :origin_url)
    endpoint = Keyword.fetch!(opts, :endpoint)
    otp_app = Keyword.fetch!(opts, :otp_app)

    Logger.info("[CloudflareTunnel] Starting quick tunnel for #{origin_url}")

    port =
      Port.open(
        {:spawn_executable, cloudflared},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ["tunnel", "--no-autoupdate", "--url", origin_url]
        ]
      )

    {:ok, %{port: port, url: nil, mode: :quick, endpoint: endpoint, otp_app: otp_app}}
  end

  defp init_mode(:named, cloudflared, opts) do
    if opts[:tunnel_secret] in [nil, ""] do
      Logger.warning("[CloudflareTunnel] No tunnel_secret configured — tunnel disabled")
      :ignore
    else
      hostname = Keyword.fetch!(opts, :hostname)
      endpoint = Keyword.fetch!(opts, :endpoint)
      otp_app = Keyword.fetch!(opts, :otp_app)

      write_config(opts)
      Logger.info("[CloudflareTunnel] Starting named tunnel → https://#{hostname}")

      port =
        Port.open(
          {:spawn_executable, cloudflared},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: ["tunnel", "--no-autoupdate", "run"]
          ]
        )

      url = "https://#{hostname}"
      configure_endpoint(url, %{endpoint: endpoint, otp_app: otp_app})

      {:ok, %{port: port, url: url, mode: :named, endpoint: endpoint, otp_app: otp_app}}
    end
  end

  @impl true
  def handle_call(:url, _from, state) do
    {:reply, state.url, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    for line <- String.split(data, "\n", trim: true) do
      Logger.debug("[CloudflareTunnel] #{line}")
    end

    state =
      if state.mode == :quick and is_nil(state.url) do
        case parse_url(data) do
          nil ->
            state

          url ->
            Logger.info("[CloudflareTunnel] Tunnel ready → #{url}")
            configure_endpoint(url, state)
            %{state | url: url}
        end
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("[CloudflareTunnel] Process exited with status #{status}")
    {:stop, {:tunnel_exit, status}, state}
  end

  @impl true
  def terminate(_reason, %{port: port}) do
    Port.close(port)
  catch
    :error, :badarg -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp configure_endpoint(url, %{endpoint: endpoint, otp_app: otp_app}) do
    uri = URI.parse(url)

    current = Application.get_env(otp_app, endpoint, [])
    updated = Keyword.put(current, :url, host: uri.host, scheme: uri.scheme, port: 443)
    Application.put_env(otp_app, endpoint, updated)

    if function_exported?(endpoint, :config_change, 2) do
      endpoint.config_change([{endpoint, updated}], [])
    end
  end

  defp write_config(opts) do
    base_dir = Keyword.get(opts, :base_dir, Path.join(File.cwd!(), "tmp/cloudflared"))
    File.mkdir_p!(base_dir)
    credentials_path = write_credentials(opts, base_dir)

    yaml = """
    tunnel: #{opts[:tunnel_id]}
    credentials-file: #{credentials_path}

    ingress:
      - hostname: #{opts[:hostname]}
        service: #{opts[:origin_url]}
      - service: http_status:404
    """

    config_dir = Keyword.get(opts, :config_dir, Path.expand("~/.cloudflared"))
    File.mkdir_p!(config_dir)
    path = Path.join(config_dir, "config.yml")
    File.write!(path, yaml)
    path
  end

  defp write_credentials(opts, base_dir) do
    json =
      Jason.encode!(%{
        "AccountTag" => opts[:account_tag],
        "TunnelSecret" => opts[:tunnel_secret],
        "TunnelID" => opts[:tunnel_id],
        "Endpoint" => ""
      })

    path = Path.join(base_dir, "credentials.json")
    File.write!(path, json)
    path
  end
end
