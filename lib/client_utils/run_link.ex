defmodule ClientUtils.RunLink do
  @moduledoc """
  A test run's link to the CodeMySpec harness that started it.

  The harness names itself in the run's environment: `CMS_HARNESS_NODE`,
  `CMS_HARNESS_COOKIE` and `CMS_RUN_ID`, and optionally `CMS_RUN_LISTENER`,
  the process to report to (by default the harness's `CmsHarness.RunLink`).
  The run joins that node and sends each event as it happens to that process.
  It halts when that process goes away, so a run never outlives its harness.
  A run started with none of these runs as a plain `mix test`.
  """

  @default_listener "Elixir.CmsHarness.RunLink"

  defstruct [:harness, :listener, :run_id]

  @type t :: %__MODULE__{harness: node(), listener: atom(), run_id: integer()}

  @doc """
  Join the harness named in the environment, or `nil` when none is named.
  A harness that is named but cannot be reached halts the run before any test.
  """
  @spec join() :: t() | nil
  def join do
    case System.get_env("CMS_HARNESS_NODE") do
      blank when blank in [nil, ""] -> nil
      harness -> join(String.to_atom(harness))
    end
  end

  # The run's BEAM is distributed from boot by the harness (`ELIXIR_ERL_OPTIONS`).
  # Distribution is never started here: `mix test` is still requiring test
  # files in parallel, and a process minted as `nonode@nohost` reads as a
  # foreign pid once the node gets a name. A BEAM that is not distributed —
  # a harness too old to name it — runs as a plain `mix test`.
  defp join(harness) do
    if Node.alive?() do
      link(harness)
    else
      IO.puts(:stderr, "CodeMySpec: this run's BEAM is not distributed; not reporting live.")
      nil
    end
  end

  defp link(harness) do
    run_id = String.to_integer(System.fetch_env!("CMS_RUN_ID"))
    listener = String.to_atom(System.get_env("CMS_RUN_LISTENER") || @default_listener)

    if Node.connect(harness) == true and listening?(harness, listener) do
      watch(harness, listener)
      %__MODULE__{harness: harness, listener: listener, run_id: run_id}
    else
      IO.puts(:stderr, "CodeMySpec: no harness at #{harness} to report to; not running.")
      System.halt(2)
    end
  end

  @doc "Send one event to the harness. A run without a link sends nothing."
  @spec report(t() | nil, map()) :: :ok
  def report(nil, _event), do: :ok
  def report(_link, nil), do: :ok

  def report(%__MODULE__{harness: harness, listener: listener, run_id: run_id}, event) do
    send({listener, harness}, {:run_event, run_id, event})
    :ok
  end

  defp listening?(harness, listener),
    do: is_pid(:rpc.call(harness, Process, :whereis, [listener]))

  # The run halts the moment its harness's process or node goes away.
  defp watch(harness, listener) do
    spawn(fn ->
      ref = Process.monitor({listener, harness})

      receive do
        {:DOWN, ^ref, _, _, _} ->
          IO.puts(:stderr, "CodeMySpec: the harness went away; stopping the run.")
          System.halt(1)
      end
    end)

    :ok
  end
end
