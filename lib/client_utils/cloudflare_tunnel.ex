defmodule ClientUtils.CloudflareTunnel do
  @moduledoc """
  GenServer that manages a Cloudflare Quick Tunnel via an Erlang port.

  Runs `cloudflared tunnel --url <origin>` which assigns a random
  `*.trycloudflare.com` URL — no account, credentials, or DNS required.

  The GenServer parses the tunnel URL from cloudflared's stdout and
  reconfigures the Phoenix endpoint so URL helpers generate correct
  public URLs.

  ## Required opts

    * `:origin_url` — local origin URL (e.g. `"http://127.0.0.1:4000"`)
    * `:endpoint` — Phoenix Endpoint module (e.g. `MyAppWeb.Endpoint`)
    * `:otp_app` — OTP app atom (e.g. `:my_app`)

  ## Optional opts

    * `:name` — GenServer name registration (default: `__MODULE__`)

  ## Usage

      # In your application.ex (dev only), AFTER the Endpoint:
      {ClientUtils.CloudflareTunnel,
        origin_url: "http://127.0.0.1:4000",
        endpoint: MyAppWeb.Endpoint,
        otp_app: :my_app}
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
    case System.find_executable("cloudflared") do
      nil ->
        Logger.warning("[CloudflareTunnel] cloudflared not found in PATH — tunnel disabled")
        :ignore

      cloudflared ->
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

        {:ok, %{port: port, url: nil, endpoint: endpoint, otp_app: otp_app}}
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
      if is_nil(state.url) do
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
end
