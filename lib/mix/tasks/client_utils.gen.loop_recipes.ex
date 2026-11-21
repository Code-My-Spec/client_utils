defmodule Mix.Tasks.ClientUtils.Gen.LoopRecipes do
  @shortdoc "Install the CodeMySpec loop's just recipes as loop.just"

  @moduledoc """
  Writes `loop.just` beside the project's `justfile`: the recipes the
  CodeMySpec loop calls (`copy-setup`, `copy-teardown`, `run`, `certify`).

      mix client_utils.gen.loop_recipes

  Run it again after upgrading client_utils to take the new recipes; it
  overwrites `loop.just` and never touches `justfile`. The justfile needs
  these two lines, once, and may then define any of the recipes itself to
  replace the shared one:

      set allow-duplicate-recipes
      import 'loop.just'
  """

  use Mix.Task

  @lines ["set allow-duplicate-recipes", "import 'loop.just'"]

  @impl true
  def run(_argv) do
    File.cp!(Application.app_dir(:client_utils, "priv/loop.just"), "loop.just")
    Mix.shell().info("wrote loop.just")

    justfile = if File.exists?("justfile"), do: File.read!("justfile"), else: ""

    case Enum.reject(@lines, &String.contains?(justfile, &1)) do
      [] -> :ok
      missing -> Mix.shell().info("add to the top of justfile:\n\n" <> Enum.join(missing, "\n"))
    end
  end
end
