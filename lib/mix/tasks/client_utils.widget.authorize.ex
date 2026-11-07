defmodule Mix.Tasks.ClientUtils.Widget.Authorize do
  use Mix.Task
  @shortdoc "Authorize widget access (use client_utils.authorize for widget and users)"
  def run(args), do: Mix.Tasks.ClientUtils.Authorize.run(args ++ ["--scope", "widget"])
end
