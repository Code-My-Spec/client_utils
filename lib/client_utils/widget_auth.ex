defmodule ClientUtils.WidgetAuth do
  @moduledoc "Compatibility entry points; shared authorization lives in CodeMySpecClient."
  alias ClientUtils.{CodeMySpecClient, Widget}

  def begin_authorization(server, project_id),
    do: CodeMySpecClient.begin_authorization(server, project_id, ["widget"])

  defdelegate poll(grant, path), to: CodeMySpecClient

  def socket_token(id, email),
    do: CodeMySpecClient.widget_socket_token(Widget.client(), id, email)

  def server_url, do: Widget.client().server_url
end
