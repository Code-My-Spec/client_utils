defmodule ClientUtils.RunLink do
  @moduledoc """
  A test run's link to the CodeMySpec harness that started it.

  The harness names itself in the run's environment: `CMS_HARNESS_NODE`,
  `CMS_HARNESS_COOKIE` and `CMS_RUN_ID`. The run joins that node and sends
  each event as it happens to the harness's `CmsHarness.RunLink` process. It
  halts when that process goes away, so a run never outlives its harness.
  A run started with none of these runs as a plain `mix test`.
  """

  @harness_process CmsHarness.RunLink

  defstruct [:harness, :run_id]

  @type t :: %__MODULE__{harness: node(), run_id: integer()}

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

  defp join(harness) do
    run_id = String.to_integer(System.fetch_env!("CMS_RUN_ID"))
    :ok = start_distribution(run_id)
    Node.set_cookie(String.to_atom(System.fetch_env!("CMS_HARNESS_COOKIE")))

    if Node.connect(harness) == true and harness_alive?(harness) do
      watch(harness)
      %__MODULE__{harness: harness, run_id: run_id}
    else
      IO.puts(:stderr, "CodeMySpec: no harness at #{harness} to report to; not running.")
      System.halt(2)
    end
  end

  @doc "Send one event to the harness. A run without a link sends nothing."
  @spec report(t() | nil, map()) :: :ok
  def report(nil, _event), do: :ok
  def report(_link, nil), do: :ok

  def report(%__MODULE__{harness: harness, run_id: run_id}, event) do
    send({@harness_process, harness}, {:run_event, run_id, event})
    :ok
  end

  defp start_distribution(run_id) do
    if Node.alive?() do
      :ok
    else
      name = :"cms_run_#{run_id}_#{System.unique_integer([:positive])}@127.0.0.1"

      case Node.start(name, :longnames) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end

  defp harness_alive?(harness),
    do: is_pid(:rpc.call(harness, Process, :whereis, [@harness_process]))

  # The run halts the moment its harness's process or node goes away.
  defp watch(harness) do
    spawn(fn ->
      ref = Process.monitor({@harness_process, harness})

      receive do
        {:DOWN, ^ref, _, _, _} ->
          IO.puts(:stderr, "CodeMySpec: the harness went away; stopping the run.")
          System.halt(1)
      end
    end)

    :ok
  end
end
