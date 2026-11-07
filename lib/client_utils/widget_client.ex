defmodule ClientUtils.WidgetClient do
  @moduledoc """
  Per-user Slipstream client bridging a logged-in user's support widget to
  CodeMySpec.

  Connects **server-side** with an owner-approved installation credential (which never reaches
  the browser), joins `conversation:<user_id>`, and relays messages between
  CodeMySpec and the user's `SupportWidgetLive` over local PubSub. Chat and
  "Report a problem" both ride this one connection. Reconnects with backoff.
  Shared by applications through `client_utils`.
  """

  use Slipstream

  require Logger

  alias ClientUtils.Widget

  def start_link(opts) do
    user_id = to_string(Keyword.fetch!(opts, :user_id))
    Slipstream.start_link(__MODULE__, Map.new(opts), name: Widget.via(user_id))
  end

  @impl Slipstream
  def init(opts) do
    user_id = to_string(opts.user_id)
    user_email = opts.user_email
    origin = Map.get(opts, :origin)

    case Widget.client() do
      %{server_url: server, credentials_path: path} when is_binary(server) and is_binary(path) ->
        socket =
          new_socket()
          |> assign(:user_id, user_id)
          |> assign(:user_email, user_email)
          |> assign(:origin, origin)
          |> assign(:topic, "conversation:#{user_id}")
          |> assign(:messages, [])
          |> assign(:connected, false)
          |> assign(:reconnect_attempts, 0)
          |> assign(:queued, [])
          |> assign(:awaiting, %{})
          |> assign(:authorizing, false)

        send(self(), :reconnect)
        {:ok, socket}

      _ ->
        Logger.warning("[WidgetClient] cannot connect: not configured")
        :ignore
    end
  end

  @impl Slipstream
  def handle_connect(socket) do
    {:ok, join(socket, socket.assigns.topic)}
  end

  @impl Slipstream
  def handle_join(_topic, _reply, socket) do
    if timer = socket.assigns[:renewal_timer], do: Process.cancel_timer(timer)
    timer = Process.send_after(self(), :renew_authorization, 720_000)

    socket =
      socket
      |> assign(:reconnect_attempts, 0)
      |> assign(:connected, true)
      |> assign(:renewal_timer, timer)

    broadcast(socket, {:connected, true})

    socket =
      socket.assigns.queued
      |> Enum.reverse()
      |> Enum.reduce(assign(socket, :queued, []), fn {from, body}, acc ->
        push_confirmed(acc, from, body)
      end)

    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(_topic, "new_message", payload, socket) do
    messages = socket.assigns.messages ++ [payload]
    socket = assign(socket, :messages, messages)
    broadcast(socket, {:new_message, payload})
    {:ok, socket}
  end

  def handle_message(_topic, _event, _payload, socket), do: {:ok, socket}

  # CodeMySpec's answer to a `send_confirmed/2` message: it was stored or it wasn't.
  @impl Slipstream
  def handle_reply(ref, reply, %{assigns: %{awaiting: awaiting}} = socket)
      when is_map_key(awaiting, ref) do
    {from, awaiting} = Map.pop(awaiting, ref)
    GenServer.reply(from, confirmation(reply))
    {:ok, assign(socket, :awaiting, awaiting)}
  end

  # Reply to a `load_older` push: prepend the previous page and re-broadcast.
  def handle_reply(_ref, {:ok, %{"messages" => older}}, socket) when is_list(older) do
    messages = older ++ socket.assigns.messages
    socket = assign(socket, :messages, messages)
    broadcast(socket, {:messages, messages})
    {:ok, socket}
  end

  # Reply to a presigned-upload request. The key's prefix says which one:
  # `chat/…` is a chat attachment, `issues/…` is a report screenshot.
  def handle_reply(_ref, {:ok, %{"upload_url" => url, "s3_key" => "chat/" <> _ = key}}, socket) do
    broadcast(socket, {:chat_upload, url, key})
    {:ok, socket}
  end

  def handle_reply(_ref, {:ok, %{"upload_url" => url, "s3_key" => key}}, socket) do
    broadcast(socket, {:screenshot_upload, url, key})
    {:ok, socket}
  end

  def handle_reply(_ref, {:ok, %{"id" => id}}, socket) do
    broadcast(socket, {:feedback_submitted, id})
    {:ok, socket}
  end

  def handle_reply(_ref, {:error, reason}, socket) do
    broadcast(socket, {:request_failed, reason})
    {:ok, socket}
  end

  def handle_reply(_ref, _reply, socket), do: {:ok, socket}

  @impl Slipstream
  def handle_call(:state, _from, socket) do
    {:reply, %{messages: socket.assigns.messages, connected: socket.assigns[:connected] == true},
     socket}
  end

  # The site this client told CodeMySpec it was connecting from. `origin` is
  # sent once, at connect, so `Widget.ensure_started/3` has to ask before
  # deciding whether a running client can be reused for a different site.
  def handle_call(:origin, _from, socket) do
    {:reply, socket.assigns[:origin], socket}
  end

  # A message whose sender waits for CodeMySpec to store it. Queued until the
  # join: a push before it is dropped with `{:error, :not_joined}`.
  def handle_call({:send_confirmed, body}, from, socket) do
    if joined?(socket, socket.assigns.topic) do
      {:noreply, push_confirmed(socket, from, body)}
    else
      {:noreply, update(socket, :queued, &[{from, body} | &1])}
    end
  end

  @impl Slipstream
  def handle_cast({:send_message, body, attachments}, socket) do
    push(socket, socket.assigns.topic, "send_message", %{
      "body" => body,
      "attachments" => attachments
    })

    {:noreply, socket}
  end

  def handle_cast({:load_older, before}, socket) do
    push(socket, socket.assigns.topic, "load_older", %{"before" => before})
    {:noreply, socket}
  end

  def handle_cast({:request_screenshot_upload, content_type}, socket) do
    push(socket, socket.assigns.topic, "request_screenshot_upload", %{
      "content_type" => content_type
    })

    {:noreply, socket}
  end

  def handle_cast({:request_chat_upload, content_type, filename}, socket) do
    push(socket, socket.assigns.topic, "request_chat_upload", %{
      "content_type" => content_type,
      "filename" => filename
    })

    {:noreply, socket}
  end

  # "Report a problem" rides the same authenticated connection as chat — pushed to
  # CodeMySpec as a `submit_feedback` event, which files an issue on the project.
  def handle_cast({:submit_feedback, payload}, socket) do
    push(socket, socket.assigns.topic, "submit_feedback", payload)
    {:noreply, socket}
  end

  @impl Slipstream
  def handle_disconnect(reason, socket) do
    if timer = socket.assigns[:renewal_timer], do: Process.cancel_timer(timer)
    attempts = socket.assigns.reconnect_attempts
    delay = backoff(attempts)
    Logger.info("[WidgetClient] disconnected (#{inspect(reason)}), reconnecting in #{delay}ms")
    Process.send_after(self(), :reconnect, delay)

    # Say so rather than reconnecting silently. A widget that looks live while
    # its backend is gone accepts a message and drops it, and the visitor
    # believes they were heard — worse than showing unavailable.
    socket = socket |> assign(:connected, false) |> assign(:reconnect_attempts, attempts + 1)
    broadcast(socket, {:connected, false})

    # Their replies died with the connection.
    for {_ref, from} <- socket.assigns.awaiting,
        do: GenServer.reply(from, {:error, :disconnected})

    {:ok, assign(socket, :awaiting, %{})}
  end

  @impl Slipstream
  def handle_info(:renew_authorization, socket), do: {:noreply, authorize(socket, :renew)}

  def handle_info(:reconnect, %{assigns: %{connected: true}} = socket), do: {:noreply, socket}
  def handle_info(:reconnect, socket), do: {:noreply, authorize(socket, :connect)}

  def handle_info({:authorized, mode, result}, socket) do
    socket = assign(socket, :authorizing, false)
    {:noreply, apply_authorization(socket, mode, result)}
  end

  defp authorize(%{assigns: %{authorizing: true}} = socket, _mode), do: socket

  defp authorize(socket, mode) do
    parent = self()
    client = Widget.client()

    {:ok, _} =
      Task.start(fn ->
        result =
          ClientUtils.CodeMySpecClient.widget_socket_token(
            client,
            socket.assigns.user_id,
            socket.assigns.user_email
          )

        send(parent, {:authorized, mode, result})
      end)

    assign(socket, :authorizing, true)
  end

  defp apply_authorization(socket, :connect, {:ok, token}) do
    {:ok, socket} = connect(socket, uri: build_uri(token, socket.assigns.origin))
    socket
  end

  defp apply_authorization(%{assigns: %{connected: false}} = socket, :renew, result),
    do: apply_authorization(socket, :connect, result)

  defp apply_authorization(socket, :renew, {:ok, token}) do
    case push(socket, socket.assigns.topic, "reauth", %{"socket_token" => token}) do
      {:ok, _} -> schedule_renewal(socket, 720_000)
      _ -> schedule_renewal(socket, 30_000)
    end
  end

  defp apply_authorization(socket, :renew, _), do: schedule_renewal(socket, 30_000)

  defp apply_authorization(socket, :connect, _) do
    Process.send_after(self(), :reconnect, 30_000)
    socket
  end

  defp schedule_renewal(socket, delay) do
    if timer = socket.assigns[:renewal_timer], do: Process.cancel_timer(timer)
    timer = Process.send_after(self(), :renew_authorization, delay)
    assign(socket, :renewal_timer, timer)
  end

  defp push_confirmed(socket, from, body) do
    case push(socket, socket.assigns.topic, "send_message", %{"body" => body, "attachments" => []}) do
      {:ok, ref} ->
        update(socket, :awaiting, &Map.put(&1, ref, from))

      {:error, reason} ->
        GenServer.reply(from, {:error, reason})
        socket
    end
  end

  defp confirmation(:ok), do: :ok
  defp confirmation({:ok, _}), do: :ok
  defp confirmation(:error), do: {:error, :rejected}
  defp confirmation({:error, reason}), do: {:error, reason}

  defp broadcast(socket, message) do
    Phoenix.PubSub.broadcast(
      ClientUtils.WidgetPubSub,
      Widget.topic(socket.assigns.user_id),
      message
    )
  end

  defp backoff(attempts), do: min(trunc(:math.pow(2, attempts) * 1000), 10_000)

  defp build_uri(token, origin) do
    query = URI.encode_query(%{"socket_token" => token, "origin" => origin, "vsn" => "2.0.0"})
    "#{Widget.socket_url()}/websocket?#{query}"
  end
end
