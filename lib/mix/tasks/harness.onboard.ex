defmodule Mix.Tasks.Harness.Onboard do
  @shortdoc "Configure this working copy so an agent can work in it"

  @moduledoc """
  Take the working copy this runs in from checkout to ready.

      mix harness.onboard [PATH] [--check]

  Writes the settings an agent session needs — the Anthropic base URL it relays
  model turns through, and the test partition its databases are named after —
  sets the git config the copy needs, and then names the databases it still wants
  without creating any of them.

  ## Why this lives here

  A generated application depends on `client_utils` and not on CodeMySpec, so this
  is the only place a single command can onboard both. CodeMySpec's own
  `mix cms.harness.onboard` calls the same code with its own filesystem adapter
  and adds what only it needs — minting an id against the server, and addressing
  the agent hooks.

  ## What it will not do

  **It never creates, migrates or drops a database.** It prints the exact commands
  and leaves them to you. The rule exists because the version that ran them
  shelled out to `mix` with an environment that had `MIX_ENV` scrubbed out of it,
  resolved to the shared development database, and a sibling truncate emptied it
  three times.

  **It does not create worktrees.** Make one, then run this inside it.
  """

  use Mix.Task

  alias ClientUtils.Harness.Onboarding

  @impl Mix.Task
  def run(args) do
    {opts, rest, _invalid} = OptionParser.parse(args, strict: [check: :boolean, id: :string])
    root = rest |> List.first() |> root_or_cwd()

    case Keyword.get(opts, :check, false) do
      true -> report_check(Onboarding.check(root), root)
      false -> report_onboard(Onboarding.onboard(root, onboard_opts(opts)))
    end
  end

  # The app name is required, never defaulted. Defaulting it is what produced
  # `code_my_spec_test_*` inside an application called something else — a printed
  # command that creates a different database than the one it names.
  defp onboard_opts(opts) do
    [harness_id: Keyword.get(opts, :id), app: Mix.Project.config()[:app]]
  end

  defp root_or_cwd(nil), do: File.cwd!()
  defp root_or_cwd(path), do: Path.expand(path)

  # Prints as well as returns, and the print is not decoration. An earlier version
  # only returned, so `--check` gave identical empty output whether a copy was
  # onboarded or not — the answer was real and unreachable, because a mix task's
  # return value goes to whoever called it and at a terminal that is nobody.
  defp report_check(%{onboarded: true} = status, root) do
    Mix.shell().info("onboarded: #{root}")
    status
  end

  defp report_check(%{onboarded: false, remedy: remedy} = status, root) do
    Mix.shell().info("not onboarded: #{root}\nrun: #{remedy}")
    status
  end

  defp report_onboard(report) do
    Mix.shell().info("""

    onboarded: #{report.root}
      partition:  #{report.partition}
      settings:   #{describe(report.settings)}
      submodules: #{if report.git.submodule_recurse, do: "recursing", else: "not configured"}
    """)

    Mix.shell().info("Databases this working copy needs (create and migrate them yourself):")

    Enum.each(report.databases, fn database ->
      Mix.shell().info("  #{database.name}\n    #{database.create}\n    #{database.migrate}")
    end)

    report
  end

  defp describe({:ok, path}), do: path
  defp describe({:error, reason}), do: "not written — #{inspect(reason)}"
end
