defmodule Mix.Tasks.ClientUtils.Gen.ChatWidget do
  @shortdoc "Deprecated: use the shared support widget"
  @moduledoc "The widget now lives in ClientUtils. Install host wiring with mix cms_gen.support_widget."
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.raise(
      "Use mix cms_gen.support_widget to install the shared ClientUtils widget; widget code is no longer copied into applications."
    )
  end
end
