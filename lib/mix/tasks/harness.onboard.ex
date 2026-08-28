defmodule Mix.Tasks.Harness.Onboard do
  @shortdoc "Configure this working copy so an agent can work in it"

  @moduledoc """
  Take the working copy this runs in from checkout to ready.

      mix harness.onboard [PATH] [--check] [--relay-model-turns] [--deploy-key KEY]

  Writes the settings an agent session needs — the harness id its MCP mount
  addresses with, and the test partition its databases are named after —
  sets the git config the copy needs, and then names the databases it still wants
  without creating any of them.

  ## `--deploy-key`, and why a copy needs one

  A deploy key reaches exactly one project — deliberately, so a harness on one
  project does not inherit everything its owner can do — while one harness serves
  every checkout it has a subtree for. A daemon holding a single key from its
  environment can therefore only join one project: a second project's copy
  connects its socket, has every join refused, and every hook in it answers
  "channel down, server answering 200" while the harness's own `/health` says
  connected, because that is about the socket.

  So the key is recorded in the copy's own `.cms_harness.json`, beside the
  identity it authenticates and where the harness already walks up to find it.
  Git ignores that file and it is written `0600`.

  Taken from `--deploy-key`, or from `CMS_DEPLOY_KEY` when the flag is absent.
  Get it from `<server>/app/projects/<project-id>/edit` — Generate fills the
  field, Save is what stores the hash, so a key copied without saving matches
  nothing.

  Omitting it is fine and never blanks a key already recorded. A sprite, whose
  daemon holds its one project's key in the environment, needs nothing here.

  ## `--relay-model-turns` is opt-in, and defaults off

  Passing `--relay-model-turns` also writes `ANTHROPIC_BASE_URL`, routing every
  model turn through the harness's Anthropic proxy instead of straight to
  Anthropic. That proxy only understands `/v1/messages` — no other route it
  forwards — so setting this on an interactive session silently makes anything
  else the Claude Code client needs unavailable, `/remote-control` included,
  with no error anywhere to say why. Leave it off unless something specific
  reads the recorded turns (an observability UI, a sprite).

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
    {opts, rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          check: :boolean,
          id: :string,
          relay_model_turns: :boolean,
          deploy_key: :string,
          server_url: :string
        ]
      )

    root = rest |> List.first() |> root_or_cwd()

    case Keyword.get(opts, :check, false) do
      true -> report_check(Onboarding.check(root), root)
      false -> report_onboard(Onboarding.onboard(root, onboard_opts(opts)))
    end
  end

  # The flag first, then the environment. Both are ways of saying "this copy's
  # project is this one", and the flag is the more deliberate of the two — a
  # `CMS_DEPLOY_KEY` in the shell belongs to whatever that shell was set up for,
  # which is exactly the mismatch this records against.
  defp deploy_key(opts) do
    case Keyword.get(opts, :deploy_key) do
      key when is_binary(key) and key != "" -> key
      _ -> System.get_env("CMS_DEPLOY_KEY")
    end
  end

  # The app name is required, never defaulted. Defaulting it is what produced
  # `code_my_spec_test_*` inside an application called something else — a printed
  # command that creates a different database than the one it names.
  defp onboard_opts(opts) do
    [
      harness_id: Keyword.get(opts, :id),
      app: Mix.Project.config()[:app],
      relay_model_turns: Keyword.get(opts, :relay_model_turns, false),
      deploy_key: deploy_key(opts),
      server_url: server_url(opts)
    ]
  end

  # Where to ask for this copy's preview.
  #
  # Without it `Preview.ensure/4` has no server to ask and answers `:none`, so
  # onboarding recorded no address — every time, silently, because "no preview"
  # is a legitimate answer and looks identical to "never asked". The tunnel is
  # supposed to be a *result* of onboarding a copy, and it could not be.
  #
  # Flag first, then the environment, matching `deploy_key/1`. A container is
  # handed `CMS_SERVER_URL` by whatever started it; a person running this by
  # hand passes the flag or has it exported already.
  defp server_url(opts) do
    case Keyword.get(opts, :server_url) do
      url when is_binary(url) and url != "" -> url
      _ -> System.get_env("CMS_SERVER_URL")
    end
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

  # Names the keys, because "not onboarded" alone sends the reader back to the
  # file to work out which half failed — and the case that matters most is the
  # half-onboarded copy, where the file is present and some of the keys are
  # right. That state used to print `onboarded:`.
  defp report_check(
         %{onboarded: false, missing: [_ | _] = missing, remedy: remedy} = status,
         root
       ) do
    Mix.shell().info(
      "not onboarded: #{root}\n  missing: #{Enum.join(missing, ", ")}\nrun: #{remedy}"
    )

    status
  end

  defp report_check(%{onboarded: false, remedy: remedy} = status, root) do
    Mix.shell().info("not onboarded: #{root}\nrun: #{remedy}")
    status
  end

  # The header says which of the two states this is.
  #
  # It said `onboarded:` unconditionally, including for a run that addressed
  # nothing — and `warn_no_id/0` below already knew that state was dangerous
  # enough to shout about. Shouting under a header that says the opposite is
  # worse than either alone: `mix harness.onboard` printed `onboarded:` while
  # `mix harness.onboard --check`, one command later, printed `not onboarded`
  # and named the two keys. One task, one working copy, two answers.
  #
  # Measured in the devbox on a stock generated project, 2026-08-20. An agent
  # reads the first line and moves on with hooks, MCP and model turns all
  # unaddressed; or it reads `--check`, is told to run the command, runs it, is
  # told `onboarded`, and never gets out of that loop.
  defp report_onboard(report) do
    Mix.shell().info("""

    #{headline(report)}: #{report.root}
      partition:  #{report.partition}
      settings:   #{describe(report.settings)}
      address:    #{describe_address(report.harness_id)}
      hooks:      #{describe_hooks(report.hooks)}
      submodules: #{if report.git.submodule_recurse, do: "recursing", else: "not configured"}
    """)

    if is_nil(report.harness_id), do: warn_no_id()

    Mix.shell().info("Databases this working copy needs (create and migrate them yourself):")

    Enum.each(report.databases, fn database ->
      Mix.shell().info("  #{database.name}\n    #{database.create}\n    #{database.migrate}")
    end)

    report
  end

  # The same question `check/2` answers, answered the same way. A copy without a
  # harness id has no addressed hooks, no MCP and no recorded identity, which is
  # the whole of what onboarding is for — the partition and the git config are
  # real work and are not that.
  defp headline(%{harness_id: nil}), do: "partially onboarded"
  defp headline(_report), do: "onboarded"

  defp describe_address(nil), do: "not addressed — no harness id"
  defp describe_address(id), do: "addressed (#{id})"

  defp describe_hooks({:ok, :skipped}), do: "not addressed — no harness id"
  defp describe_hooks({:ok, path}), do: path
  defp describe_hooks({:error, reason}), do: "not written — #{inspect(reason)}"

  # Loud, not just absent from the summary above. This is the exact half-onboarded
  # state a silent success used to leave behind — the copy printed "onboarded:"
  # while ANTHROPIC_BASE_URL and CMS_HARNESS_ID were still whatever an earlier
  # run left (nothing, on a first run), and every hook and model turn kept
  # answering confidently about a working copy that was never actually
  # addressed.
  defp warn_no_id do
    Mix.shell().info("""

    No harness id was given, so hooks, MCP and model turns are NOT addressed
    yet — nothing else in this run overwrote a working address if one was
    already here, but a first-time onboard stops here unaddressed.

    Run again with the id this working copy was issued:

        mix harness.onboard --id <id>
    """)
  end

  defp describe({:ok, path}), do: path
  defp describe({:error, reason}), do: "not written — #{inspect(reason)}"
end
