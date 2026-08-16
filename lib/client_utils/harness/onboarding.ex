defmodule ClientUtils.Harness.Onboarding do
  @moduledoc """
  What onboarding a working copy decides, with none of the doing.

  Pure policy, so the two callers can share it without sharing anything else.
  `Mix.Tasks.Harness.Onboard` writes these results to disk for a generated
  application; CodeMySpec's `Mix.Tasks.Cms.OnboardHarness` writes the same results
  through its own environment abstraction. Neither this module nor that task
  learns what the other is.

  That split is the reason onboarding lives here rather than in CodeMySpec: a
  generated application depends on `client_utils` and not on CodeMySpec, so this
  is the only placement where both can onboard themselves with one command.

  ## Nothing here touches a disk or a database

  Every function returns a value. The commands for creating and migrating
  databases are *returned as strings* — they are handed to whoever ran the
  command, never executed. That rule is not stylistic: the version of this that
  ran them shelled out to `mix` with an environment that had `MIX_ENV` scrubbed
  out of it, resolved to the shared development database, and a sibling truncate
  emptied it three times on 2026-08-13.
  """

  @doc """
  The database partition name for a working copy at `root`.

  Assigned here **once**, at onboarding, and recorded — which is the whole point.
  Two mechanisms currently derive this independently and disagree by accident:
  `config/test.exs` builds a name from the worktree path, `TestDatabase` digests
  the cwd. The digest below is not better than either; it is only computed in one
  place and written down, and that is what makes it answerable.
  """
  @spec partition_name(String.t()) :: String.t()
  def partition_name(root) do
    digest =
      root
      |> Path.expand()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    "h#{digest}"
  end

  @doc """
  The partition recorded for the copy at `root`.

  **Read, never derived.** There is one path: onboarding assigns the partition and
  writes it down, and everything afterwards reads that. A copy with nothing
  recorded is not onboarded, and this says so rather than inventing a value.

  The fallback that used to live here was the second mechanism. Onboarding
  recorded a partition and nothing read it: `CmsHarness.TestDatabase` digested the
  cwd, `partition_name/1` digested it identically, and the analyzer set
  `MIX_TEST_PARTITION` from its own copy. They agreed because one algorithm had
  been written twice — a coincidence maintained by hand rather than a shared
  value, and recording a value nobody reads turned two derivations into three
  (acaf8035). Leaving a derive-on-miss path in the resolver would have kept both
  alive, silently, for exactly the copies nobody had onboarded.

  `partition_name/1` still exists, and is only for *assigning* a name during
  onboarding. Nothing resolves through it.

  Pass `read:` to resolve through something other than the filesystem — a 1-arity
  function taking a path relative to `root`.
  """
  @spec resolve_partition(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :not_onboarded}
  def resolve_partition(root, opts \\ []) do
    read = Keyword.get(opts, :read, &default_read(root, &1))

    case recorded_partition(read) do
      nil -> {:error, :not_onboarded}
      partition -> {:ok, partition}
    end
  end

  @doc """
  The recorded partition, or a raise naming what to run.

  For callers that cannot proceed without one. The message is the remedy, because
  a refusal whose fix is not stated is the failure this story is about.
  """
  @spec resolve_partition!(String.t(), keyword()) :: String.t()
  def resolve_partition!(root, opts \\ []) do
    case resolve_partition(root, opts) do
      {:ok, partition} ->
        partition

      {:error, :not_onboarded} ->
        raise """
        #{root} has no recorded test partition, so it has not been onboarded.

        Run: mix harness.onboard
        """
    end
  end

  defp default_read(root, path) do
    File.read(Path.join(root, path))
  end

  defp recorded_partition(read) do
    with {:ok, contents} <- read.(settings_path()),
         {:ok, %{"env" => %{"MIX_TEST_PARTITION" => partition}}} <- Jason.decode(contents),
         true <- is_binary(partition) and partition != "" do
      partition
    else
      _ -> nil
    end
  end

  @doc """
  Every database this working copy uses, each with the commands that create and
  migrate **it**.

  Three, not one. An analyzer and an interactive session deliberately use
  different databases — running a suite and an analyzer concurrently against one
  produced 13 orphaned rows and 17 phantom failures — so reporting a single
  database hides the others, and hiding one is how an agent migrates the rest and
  stays blocked on it for three days.

    <partition>    the interactive session's `mix test`
    <partition>s   the analyzer's spex run
    <partition>a   the analyzer's exunit run

  The third is newer than the other two and closes the last pair that still
  shared. `mix harness.onboard` records `MIX_TEST_PARTITION` in
  `.claude/settings.local.json`'s `env` block so `resolve_partition!/2` can read
  it back — and Claude Code exports that block into the agent's session, so the
  agent's own `mix test` and the analyzer's exunit run resolved to the same
  name. Two full suites in one database, live every time someone tested during a
  sweep, failing in the direction of "your branch broke these tests".

  This list is what tells anyone which databases to create, and nothing creates
  them on its own: the harness names databases and does not manage them, after a
  version that shelled out to `mix` with `MIX_ENV` scrubbed and emptied dev three
  times on 2026-08-13. So a partition missing from here is a database nobody is
  told to create, and the analyzer meets it as "database does not exist".

  Each command names its own database for the same reason. The migration guard
  printed `MIX_ENV=test mix ecto.migrate` while checking a partition that command
  never touches; an agent followed it correctly and nothing changed.

  The name has **no separator** before the partition, because that is what
  `config/test.exs` composes: `"<app>_test<partition>"`. An earlier version wrote
  `_test_`, so the printed name and the database its own command created differed
  by one character — the same defect as the hardcoded prefix before it, surviving
  the fix for that one because the output was only ever compared to itself
  (c4a2acae).
  """
  @spec databases(String.t(), atom() | String.t()) :: [
          %{name: String.t(), partition: String.t(), create: String.t(), migrate: String.t()}
        ]
  def databases(partition, app) do
    Enum.map([partition, partition <> "s", partition <> "a"], fn part ->
      %{
        name: "#{app}_test#{part}",
        partition: part,
        create: "MIX_TEST_PARTITION=#{part} MIX_ENV=test mix ecto.create",
        migrate: "MIX_TEST_PARTITION=#{part} MIX_ENV=test mix ecto.migrate"
      }
    end)
  end

  @doc """
  The address an agent's model turns relay through.

  One function, both callers, on purpose. This string was rendered twice — once
  here and once in CodeMySpec's own task — and the two disagreed: `/api/harnesses/<id>`
  against `/harnesses/<id>/anthropic`, of which only the first is a real route in
  `CmsHarness.Web.Router`. A copy onboarded by the wrong one relays every turn to a
  404 and its agent's work never reaches the server.

  That is the defect this whole story exists to remove — two derivations of one
  value, disagreeing by accident — reproduced by the refactor meant to fix it, and
  hidden because each half looked right on its own. Neither half should be able to
  render this alone.

  The caller supplies the base because only it knows one: CodeMySpec reads the port
  the generated plugin was addressed to.
  """
  @spec anthropic_url(String.t(), String.t()) :: String.t()
  def anthropic_url(base_url, harness_id) do
    "#{String.trim_trailing(base_url, "/")}/api/harnesses/#{harness_id}"
  end

  @doc """
  The settings a working copy needs, as a map ready to be encoded.

  Goes to `.claude/settings.local.json`, never `.claude/settings.json`. The base
  URL carries the harness id, and `settings.json` is tracked — so writing it there
  stages one machine's identity for commit and the next clone inherits it, looking
  onboarded while talking to a harness that is not its own.
  """
  @spec settings(String.t(), String.t(), String.t()) :: map()
  def settings(harness_id, partition, base_url) do
    %{
      "env" => %{
        "ANTHROPIC_BASE_URL" => anthropic_url(base_url, harness_id),
        "MIX_TEST_PARTITION" => partition,
        "CMS_HARNESS_ID" => harness_id
      }
    }
  end

  @doc "The file settings belong in. Untracked, deliberately — see `settings/2`."
  @spec settings_path() :: String.t()
  def settings_path, do: ".claude/settings.local.json"

  @doc """
  Git settings a working copy needs.

  `submodule.recurse` because a submodule sits in detached HEAD by design and so
  accepts writes with no branch to carry them. Four QA briefs — including the
  evidence behind a story shipped with QA recorded complete — existed in exactly
  one working copy for a day because of it, and nothing reported a problem.
  """
  @spec git_config() :: [{String.t(), String.t()}]
  def git_config, do: [{"submodule.recurse", "true"}]

  @default_io ClientUtils.Harness.Onboarding.FileIO

  @doc """
  Configure the working copy at `root`, and report what is left.

  Writes the settings a copy needs, sets the git config it needs, then names the
  databases it still wants — and does not create them. Returns a report; the
  caller decides how to show it.

  Pass `io:` to route the writes somewhere other than the real filesystem. The
  default is `FileIO`, which is what a generated application gets without
  configuring anything.

  **No database is created, migrated or dropped.** The commands come back as
  strings and running them is the operator's job. The rule is not stylistic: the
  version that ran them shelled out to `mix` with an environment that had
  `MIX_ENV` scrubbed out of it, resolved to the shared development database, and a
  sibling truncate emptied it three times on 2026-08-13.

  **No worktree is created.** This configures the copy it is pointed at.
  """
  @spec onboard(String.t(), keyword()) :: map()
  def onboard(root, opts \\ []) do
    io = Keyword.get(opts, :io, @default_io)
    harness_id = Keyword.get(opts, :harness_id)
    app = Keyword.fetch!(opts, :app)
    base_url = Keyword.get(opts, :base_url, "http://localhost:4004")
    partition = partition_name(root)

    %{
      root: root,
      harness_id: harness_id,
      partition: partition,
      settings: write_settings(io, root, harness_id, partition, base_url),
      databases: databases(partition, app),
      git: %{submodule_recurse: configure_git(io, root)},
      issued_ddl: false
    }
  end

  @doc """
  Whether the copy at `root` has been onboarded, and what to run if not.

  Absence has to report itself. A missing thing that produces no error where it is
  missing surfaces somewhere else wearing another failure's costume, and stopping
  that is what onboarding is for.
  """
  @spec check(String.t(), keyword()) :: %{onboarded: boolean(), remedy: String.t()}
  def check(root, opts \\ []) do
    io = Keyword.get(opts, :io, @default_io)

    %{onboarded: io.exists?(root, settings_path()), remedy: "mix harness.onboard"}
  end

  # Merged, never stamped. The operator may have written in this file, and an
  # onboarding that overwrites their edits cannot safely be re-run — which means
  # anyone unsure whether a copy is onboarded has to reason about it instead of
  # simply running it again.
  defp write_settings(io, root, harness_id, partition, base_url) do
    with {:ok, existing} <- read_settings(io, root) do
      merged =
        Map.put(
          existing,
          "env",
          merge_env(Map.get(existing, "env", %{}), settings(harness_id, partition, base_url)["env"])
        )

      case io.write(root, settings_path(), Jason.encode!(merged, pretty: true)) do
        :ok -> {:ok, settings_path()}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # The address is corrected on every run; the partition is set once. A partition
  # that moved would rename a database that already has migrations in it.
  defp merge_env(existing, incoming) do
    existing
    |> Map.put("ANTHROPIC_BASE_URL", incoming["ANTHROPIC_BASE_URL"])
    |> Map.put("CMS_HARNESS_ID", incoming["CMS_HARNESS_ID"])
    |> Map.put_new("MIX_TEST_PARTITION", incoming["MIX_TEST_PARTITION"])
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  # Unparseable is a refusal, not an empty object. Rewriting a malformed settings
  # file from scratch destroys whatever someone was halfway through editing, and
  # half-edited is exactly the state they are in when they run this to fix it.
  defp read_settings(io, root) do
    case io.read(root, settings_path()) do
      {:ok, ""} ->
        {:ok, %{}}

      {:ok, contents} ->
        decode_settings(contents)

      _ ->
        {:ok, %{}}
    end
  end

  defp decode_settings(contents) do
    case Jason.decode(contents) do
      {:ok, %{} = settings} ->
        {:ok, settings}

      _ ->
        {:error,
         "#{settings_path()} is not valid JSON. Refusing to overwrite it — fix or " <>
           "move it and run this again."}
    end
  end

  # Reported, not raised. A copy that is not a git repository still wants its
  # identity, partition and address; aborting all of that because one `git config`
  # could not run would report the absence of a repository as a failure to onboard.
  defp configure_git(io, root) do
    Enum.reduce_while(git_config(), true, fn {key, value}, true ->
      case io.cmd(root, "git", ["config", key, value]) do
        {_out, 0} -> {:cont, true}
        _ -> {:halt, false}
      end
    end)
  end
end
