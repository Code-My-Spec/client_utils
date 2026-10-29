defmodule ClientUtils.RunLink do
  @moduledoc """
  A test run's link to the CodeMySpec harness that started it.

  The harness names itself in the run's environment: `CMS_HARNESS_NODE`,
  `CMS_HARNESS_COOKIE` and `CMS_RUN_ID`, and optionally `CMS_RUN_LISTENER`,
  the process to report to (by default the harness's `CmsHarness.RunLink`).
  The run joins that node and sends each event as it happens to that process.
  It halts when the harness process that owns it goes away, so a run never
  outlives its harness, unless it keeps a stream of its events for the harness
  to re-attach to (`outlive_harness: true`): that run finishes, and what it
  would have reported is dropped.
  A run started with none of these runs as a plain `mix test`.
  """

  @default_listener "Elixir.CmsHarness.RunLink"

  defstruct [:harness, :listener, :run_id]

  @type t :: %__MODULE__{harness: node(), listener: atom(), run_id: integer()}

  # The variables that made this BEAM the run's node are for it alone: a test
  # that shells out to `mix` would otherwise boot a child under the same node
  # name ("the name cms_run_… seems to be in use by another Erlang node").
  # Read once, then removed before any test runs.
  @run_env ~w(ELIXIR_ERL_OPTIONS CMS_HARNESS_NODE CMS_HARNESS_COOKIE CMS_RUN_ID CMS_RUN_LISTENER)

  @doc """
  Join the harness named in the environment, or `nil` when none is named.
  A harness that is named but cannot be reached halts the run before any test,
  unless the run outlives its harness (see `on_harness_lost/1`).
  """
  @spec join(keyword()) :: t() | nil
  def join(opts \\ []) do
    harness = System.get_env("CMS_HARNESS_NODE")
    run_env = for name <- @run_env, value = System.get_env(name), into: %{}, do: {name, value}
    forget_run_env()

    case harness do
      blank when blank in [nil, ""] -> nil
      harness -> join(String.to_atom(harness), run_env, opts[:outlive_harness] == true)
    end
  end

  defp forget_run_env, do: Enum.each(@run_env, &System.delete_env/1)

  # The run's BEAM is distributed from boot by the harness (`ELIXIR_ERL_OPTIONS`).
  # Distribution is never started here: `mix test` is still requiring test
  # files in parallel, and a process minted as `nonode@nohost` reads as a
  # foreign pid once the node gets a name. A BEAM that is not distributed —
  # a harness too old to name it — runs as a plain `mix test`.
  #
  # Only a hidden node links. A visible one would join `:global` with the
  # harness and every other run connected to it, and test processes registered
  # globally (`Mox.Server`, Swoosh's storage) would collide across runs: one
  # run's Mox calls landed in another's server (`badfun`). A harness that starts
  # runs visible gets a plain `mix test`.
  defp join(harness, run_env, outlive?) do
    if Node.alive?() and hidden?() do
      link(harness, run_env, outlive?)
    else
      IO.puts(:stderr, "CodeMySpec: this run's BEAM is not a hidden node; not reporting live.")
      nil
    end
  end

  defp hidden?, do: match?({:ok, _}, :init.get_argument(:hidden))

  defp link(harness, run_env, outlive?) do
    run_id = String.to_integer(Map.fetch!(run_env, "CMS_RUN_ID"))
    listener = String.to_atom(Map.get(run_env, "CMS_RUN_LISTENER", @default_listener))
    link = %__MODULE__{harness: harness, listener: listener, run_id: run_id}

    with true <- Node.connect(harness),
         true <- listening?(harness, listener) do
      watch(owner(harness, run_id) || {listener, harness}, link, outlive?)
      link
    else
      _ ->
        case on_harness_lost(outlive?) do
          :halt ->
            IO.puts(:stderr, "CodeMySpec: no harness at #{harness} to report to; not running.")
            System.halt(2)

          :continue ->
            IO.puts(
              :stderr,
              "CodeMySpec: no harness at #{harness} to report to; not reporting live."
            )

            nil
        end
    end
  end

  # The harness process that owns this run, registered there as
  # `{:cms_run, id}`; asked of the harness, since a hidden node shares no
  # `:global` with it. A harness that registers none (one older than its
  # client_utils, which as a path dependency updates first) is watched through
  # its listener instead.
  defp owner(harness, run_id) do
    case :rpc.call(harness, :global, :whereis_name, [{:cms_run, run_id}]) do
      pid when is_pid(pid) -> pid
      _ -> nil
    end
  end

  @doc "Send one event to the harness. A run without a link sends nothing."
  @spec report(t() | nil, map()) :: :ok
  def report(nil, _event), do: :ok
  def report(_link, nil), do: :ok

  def report(%__MODULE__{harness: harness, listener: listener, run_id: run_id} = link, event) do
    unless lost?(link), do: send({listener, harness}, {:run_event, run_id, event})
    :ok
  end

  @doc """
  What a run does when its harness goes away: halts, unless it outlives its
  harness, when it carries on and stops reporting.
  """
  @spec on_harness_lost(boolean()) :: :halt | :continue
  def on_harness_lost(true), do: :continue
  def on_harness_lost(false), do: :halt

  defp listening?(harness, listener),
    do: is_pid(:rpc.call(harness, Process, :whereis, [listener]))

  # The run halts the moment the process that owns it goes away: its copy
  # stopping, its harness restarting, or the run being cancelled.
  @doc false
  def watch(owner, link, outlive?) do
    spawn(fn ->
      ref = Process.monitor(owner)

      # Halt without writing first: the owner held the port this run's output
      # goes to, so with it gone a write to stderr fails and the halt is never
      # reached.
      receive do
        {:DOWN, ^ref, _, _, _} ->
          case on_harness_lost(outlive?) do
            :halt -> System.halt(1)
            :continue -> :persistent_term.put(lost_key(link), true)
          end
      end
    end)
  end

  defp lost?(link), do: :persistent_term.get(lost_key(link), false)
  defp lost_key(%__MODULE__{run_id: run_id}), do: {__MODULE__, :lost, run_id}
end
