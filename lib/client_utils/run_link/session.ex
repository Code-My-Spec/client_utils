defmodule ClientUtils.RunLink.Session do
  @moduledoc """
  A run's side of its link to the harness, registered on the run's node.

  Each event gets the next `seq` and is held until the harness acknowledges
  it (`{:run_ack, run_id, seq}` acknowledges everything up to `seq`). While
  connected, it is sent as `{:run_event, run_id, session, seq, event}` (the
  session's pid, as spex shards share a run id and each counts from 1) to the harness's
  listener. When the listener goes, the run carries on: about once a second
  it looks for a listening harness (the one it was started by, or another on
  the same host under the same name prefix, since a restarted harness has a
  new node name), and on finding one sends `{:run_rejoin, run_id, node(),
  session}` and replays what was not acknowledged, in order.

  A harness answers a rejoin with `{:run_adopted, run_id}` before anything is
  replayed, or `{:run_refused, run_id}` when it does not serve this run (two
  harnesses on one host), and the session tries the next one.

  `{:run_cancel, run_id}` halts the run. `finish/2`, from the run's exit,
  reports its exit status as the last event and waits until a harness has
  acknowledged every event. The run waits for a harness, but not forever: one
  that no harness has adopted for an hour (`:orphan_ms`) halts itself with
  status 75. Nothing it can reach will ever take it, and its harness's own
  ceiling (half that) has long passed.

  The harness's cookie (`:cookie`) is set for each harness the run tries, so
  the run's node can be on any other cookie (`ClientUtils.RunLink`).
  """

  use GenServer

  @retry_ms 1_000
  @adopt_ms 5_000
  @orphan_ms :timer.hours(1)
  @orphan_status 75

  @doc "Start the session, unlinked: a test crashing must not take the link with it."
  def start(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start(__MODULE__, opts)
      name -> GenServer.start(__MODULE__, opts, name: name)
    end
  end

  def run_id(session), do: GenServer.call(session, :run_id)

  def report(session, event), do: GenServer.cast(session, {:report, event})

  @doc "Report the run's exit status and wait until a harness has every event."
  def finish(session, status) do
    GenServer.call(session, {:finish, status}, :infinity)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(opts) do
    state = %{
      run_id: Keyword.fetch!(opts, :run_id),
      harness: Keyword.fetch!(opts, :harness),
      listener: Keyword.fetch!(opts, :listener),
      shard: Keyword.get(opts, :shard),
      retry_ms: Keyword.get(opts, :retry_ms, @retry_ms),
      adopt_ms: Keyword.get(opts, :adopt_ms, @adopt_ms),
      orphan_ms: Keyword.get(opts, :orphan_ms, @orphan_ms),
      cookie: Keyword.get(opts, :cookie),
      unadopted_since: System.monotonic_time(:millisecond),
      transport: Map.merge(transport(), Map.new(Keyword.get(opts, :transport, %{}))),
      output: redirect(Keyword.get(opts, :output)),
      seq: 0,
      unacked: [],
      connected: nil,
      refused: MapSet.new(),
      finishing: [],
      exited: false
    }

    {:ok, attach(state)}
  end

  @impl true
  def handle_call(:run_id, _from, state), do: {:reply, state.run_id, state}

  # Once: the formatter reports the exit when the suite finishes, and the
  # run's exit waits on that report rather than sending a second.
  def handle_call({:finish, _status}, from, %{exited: true} = state),
    do: {:noreply, settle(%{state | finishing: [from | state.finishing]})}

  def handle_call({:finish, status}, from, state) do
    state =
      put_event(state, Map.merge(%{"event" => "exit", "status" => status}, state.shard || %{}))

    {:noreply, settle(%{state | finishing: [from | state.finishing], exited: true})}
  end

  @impl true
  def handle_cast({:report, event}, state), do: {:noreply, put_event(state, event)}

  @impl true
  def handle_info({:run_ack, run_id, seq}, %{run_id: run_id} = state) do
    state = %{state | unacked: Enum.drop_while(state.unacked, fn {s, _} -> s <= seq end)}
    {:noreply, settle(state)}
  end

  def handle_info({:run_cancel, run_id}, %{run_id: run_id} = state) do
    state.transport.halt.(2)
    {:noreply, state}
  end

  def handle_info(
        {:run_adopted, run_id},
        %{run_id: run_id, connected: {node, ref, :pending}} = state
      ) do
    dest = {state.listener, node}

    Enum.each(state.unacked, fn {seq, event} ->
      state.transport.send.(dest, {:run_event, state.run_id, self(), seq, event})
    end)

    {:noreply, %{state | connected: {node, ref}, refused: MapSet.new(), unadopted_since: nil}}
  end

  def handle_info(
        {:run_refused, run_id},
        %{run_id: run_id, connected: {node, _, :pending}} = state
      ),
      do: {:noreply, refuse(state, node)}

  def handle_info({:adopt_timeout, node}, %{connected: {node, _, :pending}} = state),
    do: {:noreply, refuse(state, node)}

  def handle_info({:DOWN, ref, :process, _, _}, %{connected: {_node, ref}} = state),
    do: {:noreply, detach(state)}

  def handle_info({:DOWN, ref, :process, _, _}, %{connected: {_node, ref, :pending}} = state),
    do: {:noreply, detach(state)}

  def handle_info(:retry, %{connected: nil} = state) do
    if orphaned?(state) do
      IO.puts(
        :stderr,
        "CodeMySpec: no harness has adopted run #{state.run_id} in #{state.orphan_ms}ms; halting."
      )

      state.transport.halt.(@orphan_status)
      {:noreply, state}
    else
      {:noreply, attach(state)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp put_event(state, event) do
    seq = state.seq + 1
    state = %{state | seq: seq, unacked: state.unacked ++ [{seq, event}]}

    # Only to an adopting harness: a pending one gets the replay once it adopts.
    with {node, _ref} <- state.connected,
         do:
           state.transport.send.(
             {state.listener, node},
             {:run_event, state.run_id, self(), seq, event}
           )

    state
  end

  defp settle(%{finishing: [_ | _] = waiting, unacked: []} = state) do
    Enum.each(waiting, &GenServer.reply(&1, :ok))
    %{state | finishing: []}
  end

  defp settle(state), do: state

  defp detach(state) do
    Process.send_after(self(), :retry, state.retry_ms)
    %{state | connected: nil, unadopted_since: state.unadopted_since || now()}
  end

  defp orphaned?(%{unadopted_since: nil}), do: false
  defp orphaned?(state), do: now() - state.unadopted_since >= state.orphan_ms

  defp now, do: System.monotonic_time(:millisecond)

  # A harness that does not serve this run: skipped until one adopts it.
  defp refuse(%{connected: {node, ref, :pending}} = state, node) do
    state.transport.demonitor.(ref)
    detach(%{state | refused: MapSet.put(state.refused, node)})
  end

  defp attach(state) do
    t = state.transport
    candidates = candidates(state) -- MapSet.to_list(state.refused)
    set_cookie(state, candidates)

    listening =
      Enum.find(candidates, &(t.connect.(&1) and t.listening?.(&1, state.listener)))

    case listening do
      nil ->
        # Every harness refused: start over, a refusal is not forever.
        Process.send_after(self(), :retry, state.retry_ms)
        %{state | refused: MapSet.new()}

      node ->
        dest = {state.listener, node}
        ref = t.monitor.(dest)
        t.send.(dest, {:run_rejoin, state.run_id, node(), self()})
        Process.send_after(self(), {:adopt_timeout, node}, state.adopt_ms)
        %{state | connected: {node, ref, :pending}}
    end
  end

  # The harness the run was started by first, then any other harness on its
  # host under the same name prefix: a restarted harness is named for its new
  # OS pid (`cms_harness_<pid>@host`).
  defp candidates(%{harness: harness, transport: t}) do
    [name, host] = harness |> Atom.to_string() |> String.split("@", parts: 2)
    prefix = String.replace(name, ~r/_\d+$/, "") <> "_"

    others =
      for other <- t.names.(host), String.starts_with?(other, prefix), do: :"#{other}@#{host}"

    Enum.uniq([harness | others])
  end

  defp set_cookie(%{cookie: nil}, _nodes), do: :ok

  defp set_cookie(state, nodes),
    do: Enum.each(nodes, &state.transport.set_cookie.(&1, state.cookie))

  defp redirect(nil), do: nil
  defp redirect(path), do: ClientUtils.RunLink.redirect_output(path)

  defp transport do
    %{
      connect: &Node.connect/1,
      listening?: fn node, listener ->
        is_pid(:rpc.call(node, Process, :whereis, [listener], 5_000))
      end,
      monitor: &Process.monitor/1,
      demonitor: &Process.demonitor(&1, [:flush]),
      send: &send/2,
      names: &epmd_names/1,
      halt: &System.halt/1,
      set_cookie: &:erlang.set_cookie/2
    }
  end

  defp epmd_names(host) do
    case :erl_epmd.names(String.to_charlist(host)) do
      {:ok, names} -> Enum.map(names, fn {name, _port} -> List.to_string(name) end)
      _ -> []
    end
  end
end
