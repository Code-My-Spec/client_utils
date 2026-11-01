defmodule ClientUtils.RunLink do
  @moduledoc """
  A run's link to the CodeMySpec harness that started it.

  The harness names itself in the run's environment: `CMS_HARNESS_NODE`,
  `CMS_HARNESS_COOKIE` and `CMS_RUN_ID`, and optionally `CMS_RUN_LISTENER`,
  the process to report to (by default the harness's `CmsHarness.RunLink`).
  The run joins that node and sends each event, numbered, to that process.

  A run outlives its harness. Its events are held until the harness
  acknowledges them; when the harness goes, the run carries on, rejoins a
  harness that adopts it, and replays what was not acknowledged
  (`ClientUtils.RunLink.Session`). The run does not exit until its last event,
  its exit status, is acknowledged.

  Its output goes to `CMS_RUN_OUTPUT`, not the harness's pipe, so nothing it
  prints fails once that pipe is gone.

  A run started with none of these runs as a plain `mix test`.
  """

  alias ClientUtils.RunLink.Session

  defstruct [:session, :run_id]

  @type t :: %__MODULE__{session: pid(), run_id: integer()}

  @default_listener "Elixir.CmsHarness.RunLink"

  # The variables that made this BEAM the run's node are for it alone: a test
  # that shells out to `mix` would otherwise boot a child under the same node
  # name ("the name cms_run_… seems to be in use by another Erlang node").
  # Read once, then removed before any test runs. The shard's numbering too: a
  # run a test starts (a spex driving a fixture's suite) inherited it, reported
  # its exit as one shard of several, and was never finished.
  @run_env ~w(ELIXIR_ERL_OPTIONS CMS_HARNESS_NODE CMS_HARNESS_COOKIE CMS_RUN_ID CMS_RUN_LISTENER
              CMS_RUN_OUTPUT CMS_RUN_SHARD CMS_RUN_SHARDS)

  @doc """
  Join the harness named in the environment, or `nil` when none is named. A
  second join in the same run returns the same link.
  """
  @spec join(keyword()) :: t() | nil
  def join(opts \\ []) do
    case Process.whereis(Session) do
      nil -> join_from_env(opts)
      session -> %__MODULE__{session: session, run_id: Session.run_id(session)}
    end
  end

  defp join_from_env(opts) do
    run_env = for name <- @run_env, value = System.get_env(name), into: %{}, do: {name, value}

    Enum.each(@run_env, &System.delete_env/1)

    case run_env["CMS_HARNESS_NODE"] do
      blank when blank in [nil, ""] -> nil
      harness -> link(String.to_atom(harness), run_env, opts)
    end
  end

  # The run's BEAM is distributed from boot by the harness (`ELIXIR_ERL_OPTIONS`).
  # Distribution is never started here: `mix test` is still requiring test
  # files in parallel, and a process minted as `nonode@nohost` reads as a
  # foreign pid once the node gets a name.
  #
  # Only a hidden node links. A visible one would join `:global` with the
  # harness and every other run connected to it, and test processes registered
  # globally (`Mox.Server`, Swoosh's storage) would collide across runs.
  defp link(harness, run_env, opts) do
    if Node.alive?() and hidden?() do
      run_id = String.to_integer(Map.fetch!(run_env, "CMS_RUN_ID"))
      shard = shard(run_env)

      {:ok, session} =
        Session.start(
          Keyword.merge(
            [
              run_id: run_id,
              harness: harness,
              listener: String.to_atom(Map.get(run_env, "CMS_RUN_LISTENER", @default_listener)),
              output: shard_path(run_env["CMS_RUN_OUTPUT"], shard),
              shard: shard,
              # Booted with it (`-setcookie`), so the harness can halt a run
              # that hangs before it gets here.
              cookie: Node.get_cookie()
            ],
            opts
          )
        )

      use_user_cookie()
      System.at_exit(fn status -> Session.finish(session, status) end)
      %__MODULE__{session: session, run_id: run_id}
    else
      IO.puts(:stderr, "CodeMySpec: this run's BEAM is not a hidden node; not reporting live.")
      nil
    end
  end

  defp hidden?, do: match?({:ok, _}, :init.get_argument(:hidden))

  # The harness's cookie stays the session's, for the harness alone; every
  # other node the run's tests start (`:peer`) reads the user's cookie file and
  # was refused. Read where `erl` reads it (`auth`: the home directory, which
  # on Windows is %USERPROFILE%, then the XDG config directory). With no file,
  # the node keeps the cookie it booted with.
  defp use_user_cookie do
    with [path | _] <- Enum.filter(cookie_paths(), &File.regular?/1),
         {:ok, contents} <- File.read(path),
         cookie when cookie != "" <-
           contents |> String.split(["\n", "\r"]) |> hd() |> String.trim() do
      Node.set_cookie(String.to_atom(cookie))
    end

    :ok
  end

  defp cookie_paths do
    xdg = Path.join(List.to_string(:filename.basedir(:user_config, ~c"erlang")), ".erlang.cookie")

    case :init.get_argument(:home) do
      {:ok, [[home] | _]} -> [Path.join(List.to_string(home), ".erlang.cookie"), xdg]
      _ -> [xdg]
    end
  end

  # One of a run's `CMS_RUN_SHARDS` processes, each with its own files.
  defp shard(run_env) do
    with {shard, ""} <- Integer.parse(run_env["CMS_RUN_SHARD"] || ""),
         {shards, ""} <- Integer.parse(run_env["CMS_RUN_SHARDS"] || "") do
      %{"shard" => shard, "shards" => shards}
    else
      _ -> nil
    end
  end

  defp shard_path(blank, _shard) when blank in [nil, ""], do: nil
  defp shard_path(path, nil), do: path
  defp shard_path(path, %{"shard" => shard}), do: "#{path}.shard-#{shard}"

  @doc "Send one event to the harness. A run without a link sends nothing."
  @spec report(t() | nil, map() | nil) :: :ok
  def report(nil, _event), do: :ok
  def report(_link, nil), do: :ok
  def report(%__MODULE__{session: session}, event), do: Session.report(session, event)

  @doc """
  Report the run's exit status and wait until a harness has every event. Its
  first caller decides the status; the run's exit, which calls it again, waits
  on the same report. A runner that halts (sexy_spex does) skips the exit, so
  the formatter reports it when the suite finishes.
  """
  @spec finish(t() | nil, integer()) :: :ok
  def finish(nil, _status), do: :ok
  def finish(%__MODULE__{session: session}, status), do: Session.finish(session, status)

  # The run's stdio goes to its own file, opened by this process, which
  # outlives every test: once the harness's pipe is gone, a write to it fails
  # (`:terminated`) and so would every test that prints.
  @doc """
  Send this BEAM's stdio to `path`, appended: `:user` and `:standard_error` are
  re-registered to file devices and every process whose group leader was the
  old `:user` follows. The devices belong to the caller, which must outlive
  every test. Also for a run's parent task (`mix cms.spex`), which prints its
  shards' output and must survive the harness's pipe closing too.
  """
  @spec redirect_output(Path.t()) :: Path.t()
  def redirect_output(path) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, out} = File.open(path, [:append, :utf8])
    {:ok, err} = File.open(path, [:append, :utf8])
    user = Process.whereis(:user)

    rename(:user, out)
    rename(:standard_error, err)

    for pid <- Process.list(),
        Process.info(pid, :group_leader) == {:group_leader, user},
        do: follow(pid, out)

    path
  end

  @doc false
  # A process can exit between the listing and the move, and moving a dead one
  # raises: under load that took down the run's session as it started, and the
  # run then never linked (it ran with no link and no results file).
  @spec follow(pid(), pid()) :: :ok
  def follow(pid, device) do
    Process.group_leader(pid, device)
    :ok
  rescue
    error in ArgumentError ->
      if Process.alive?(pid), do: reraise(error, __STACKTRACE__), else: :ok
  end

  defp rename(name, pid) do
    if Process.whereis(name), do: Process.unregister(name)
    Process.register(pid, name)
  end
end
