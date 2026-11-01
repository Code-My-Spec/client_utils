defmodule ClientUtils.RunLinkTest do
  @moduledoc """
  The run's side of its link, with its node and transport injected: which
  harness nodes answer is this test's to say, and every message the session
  sends comes here.
  """
  use ExUnit.Case, async: true

  alias ClientUtils.RunLink.Session

  @harness :cms_harness_100@host
  @restarted :cms_harness_200@host
  @listener :listener

  setup do
    {:ok, up} = Agent.start_link(fn -> MapSet.new() end)
    %{up: up, run_id: System.unique_integer([:positive])}
  end

  defp start(ctx, opts \\ []) do
    test = self()
    up = ctx.up

    transport = %{
      connect: fn node -> Agent.get(up, &MapSet.member?(&1, node)) end,
      listening?: fn node, _listener -> Agent.get(up, &MapSet.member?(&1, node)) end,
      monitor: fn dest ->
        ref = make_ref()
        send(test, {:monitored, dest, ref})
        ref
      end,
      demonitor: fn ref -> send(test, {:demonitored, ref}) end,
      send: fn dest, message -> send(test, {:sent, dest, message}) end,
      names: fn "host" -> ["cms_harness_200", "cms_app_300", "epmd_other"] end,
      halt: fn status -> send(test, {:halted, status}) end,
      set_cookie: fn node, cookie -> send(test, {:cookie, node, cookie}) end
    }

    {:ok, session} =
      Session.start(
        Keyword.merge(
          [
            name: nil,
            run_id: ctx.run_id,
            harness: @harness,
            listener: @listener,
            transport: transport,
            retry_ms: 10
          ],
          opts
        )
      )

    on_exit(fn -> Process.exit(session, :kill) end)
    session
  end

  defp up(ctx, node), do: Agent.update(ctx.up, &MapSet.put(&1, node))
  defp down(ctx, node), do: Agent.update(ctx.up, &MapSet.delete(&1, node))

  test "a joined run numbers its events and sends each to the harness", ctx do
    up(ctx, @harness)
    session = start(ctx)
    run_id = ctx.run_id

    assert_receive {:sent, {@listener, @harness}, {:run_rejoin, ^run_id, _node, ^session}}
    send(session, {:run_adopted, run_id})

    Session.report(session, %{"event" => "test", "name" => "a"})
    Session.report(session, %{"event" => "test", "name" => "b"})

    assert_receive {:sent, _, {:run_event, ^run_id, _session, 1, %{"name" => "a"}}}
    assert_receive {:sent, _, {:run_event, ^run_id, _session, 2, %{"name" => "b"}}}
  end

  test "a restarted harness gets what the old one never acknowledged, in order", ctx do
    up(ctx, @harness)
    session = start(ctx)
    run_id = ctx.run_id
    assert_receive {:monitored, {@listener, @harness}, ref}
    send(session, {:run_adopted, run_id})

    for name <- ~w(a b c), do: Session.report(session, %{"event" => "test", "name" => name})
    send(session, {:run_ack, run_id, 1})

    # The harness goes; the run carries on and reports one more.
    down(ctx, @harness)
    send(session, {:DOWN, ref, :process, {@listener, @harness}, :noconnection})
    Session.report(session, %{"event" => "test", "name" => "d"})
    refute_receive {:sent, _, {:run_event, ^run_id, _session, 4, _}}, 50

    # It comes back under a new node name, as a restart does.
    flush_sent()
    up(ctx, @restarted)

    assert_receive {:sent, {@listener, @restarted}, {:run_rejoin, ^run_id, _, ^session}}
    refute_receive {:sent, _, {:run_event, _, _session, _, _}}, 50
    send(session, {:run_adopted, run_id})

    assert_receive {:sent, {@listener, @restarted},
                    {:run_event, ^run_id, _session, 2, %{"name" => "b"}}}

    assert_receive {:sent, {@listener, @restarted},
                    {:run_event, ^run_id, _session, 3, %{"name" => "c"}}}

    assert_receive {:sent, {@listener, @restarted},
                    {:run_event, ^run_id, _session, 4, %{"name" => "d"}}}

    refute_receive {:sent, _, {:run_event, ^run_id, _session, 1, _}}, 50
  end

  test "a run that starts with no harness holds its events for the first that listens", ctx do
    session = start(ctx)
    run_id = ctx.run_id
    Session.report(session, %{"event" => "test", "name" => "a"})
    refute_receive {:sent, _, _}, 50

    up(ctx, @harness)

    assert_receive {:sent, _, {:run_rejoin, ^run_id, _, ^session}}
    send(session, {:run_adopted, run_id})
    assert_receive {:sent, _, {:run_event, ^run_id, _session, 1, %{"name" => "a"}}}
  end

  test "another kind of node on the host is not taken for a harness", ctx do
    up(ctx, :cms_app_300@host)
    start(ctx)

    refute_receive {:sent, _, _}, 100
  end

  test "a cancelled run halts", ctx do
    up(ctx, @harness)
    session = start(ctx)
    send(session, {:run_cancel, ctx.run_id})

    assert_receive {:halted, 2}
  end

  test "a run exits once the harness has acknowledged its exit status", ctx do
    up(ctx, @harness)
    session = start(ctx, shard: %{"shard" => 2, "shards" => 4})
    run_id = ctx.run_id
    assert_receive {:sent, _, {:run_rejoin, ^run_id, _, ^session}}
    send(session, {:run_adopted, run_id})
    finishing = Task.async(fn -> Session.finish(session, 1) end)

    assert_receive {:sent, _,
                    {:run_event, ^run_id, _session, 1,
                     %{"event" => "exit", "status" => 1, "shard" => 2, "shards" => 4}}}

    refute Task.yield(finishing, 50)
    send(session, {:run_ack, run_id, 1})
    assert Task.await(finishing) == :ok
  end

  # The formatter reports the exit when the suite finishes, since a runner
  # that halts (sexy_spex) skips the run's exit; the exit then waits on that
  # report, not sending a second the harness would never acknowledge.
  test "the exit is reported once, and a second finish waits on the first", ctx do
    up(ctx, @harness)
    session = start(ctx)
    run_id = ctx.run_id
    assert_receive {:sent, _, {:run_rejoin, ^run_id, _, ^session}}
    send(session, {:run_adopted, run_id})

    from_formatter = Task.async(fn -> Session.finish(session, 2) end)
    assert_receive {:sent, _, {:run_event, ^run_id, _, 1, %{"event" => "exit", "status" => 2}}}

    from_exit = Task.async(fn -> Session.finish(session, 2) end)
    refute_receive {:sent, _, {:run_event, ^run_id, _, 2, _}}, 50
    refute Task.yield(from_exit, 0)

    send(session, {:run_ack, run_id, 1})
    assert Task.await(from_formatter) == :ok
    assert Task.await(from_exit) == :ok
  end

  test "a harness that does not serve the run refuses it, and the run tries the next", ctx do
    up(ctx, @harness)
    up(ctx, @restarted)
    session = start(ctx)
    run_id = ctx.run_id
    Session.report(session, %{"event" => "test", "name" => "a"})

    assert_receive {:sent, {@listener, @harness}, {:run_rejoin, ^run_id, _, ^session}}
    send(session, {:run_refused, run_id})

    assert_receive {:sent, {@listener, @restarted}, {:run_rejoin, ^run_id, _, ^session}}
    send(session, {:run_adopted, run_id})

    assert_receive {:sent, {@listener, @restarted},
                    {:run_event, ^run_id, _session, 1, %{"name" => "a"}}}

    refute_receive {:sent, {@listener, @harness}, {:run_event, _, _session, _, _}}, 50
  end

  test "a harness that never answers the rejoin is passed over", ctx do
    up(ctx, @harness)
    up(ctx, @restarted)
    session = start(ctx, adopt_ms: 20)
    run_id = ctx.run_id

    assert_receive {:sent, {@listener, @harness}, {:run_rejoin, ^run_id, _, ^session}}
    assert_receive {:sent, {@listener, @restarted}, {:run_rejoin, ^run_id, _, ^session}}
  end

  test "a run that no harness adopts waits for one, within its ceiling", ctx do
    session = start(ctx)
    finishing = Task.async(fn -> Session.finish(session, 0) end)

    refute Task.yield(finishing, 200)
    refute_received {:halted, _}
    Task.shutdown(finishing, :brutal_kill)
  end

  # Prod spex run 831's shards ran on for hours after their run was closed:
  # nothing they could reach would ever adopt them.
  test "a run that no harness adopts for its whole ceiling halts itself", ctx do
    start(ctx, orphan_ms: 50)

    assert_receive {:halted, 75}, 2_000
  end

  test "a harness gone for less than the ceiling does not halt the run", ctx do
    up(ctx, @harness)
    session = start(ctx, orphan_ms: 300)
    run_id = ctx.run_id
    assert_receive {:sent, _, {:run_rejoin, ^run_id, _, ^session}}
    send(session, {:run_adopted, run_id})
    assert_receive {:monitored, _, ref}

    # Adopted for longer than the ceiling, then a restart that takes a while.
    Process.sleep(400)
    down(ctx, @harness)
    send(session, {:DOWN, ref, :process, self(), :noconnection})
    Process.sleep(150)
    up(ctx, @restarted)
    assert_receive {:sent, {@listener, @restarted}, {:run_rejoin, ^run_id, _, ^session}}, 1_000
    send(session, {:run_adopted, run_id})

    refute_receive {:halted, _}, 500
  end

  # A packaged harness's cookie is its release's own; the run keeps it for the
  # harness alone (the rest of its node is back on the user's cookie).
  test "the harness's cookie is set for each harness the run tries", ctx do
    up(ctx, @restarted)
    session = start(ctx, cookie: :harness_cookie)
    run_id = ctx.run_id

    assert_receive {:cookie, @harness, :harness_cookie}
    assert_receive {:cookie, @restarted, :harness_cookie}
    assert_receive {:sent, {@listener, @restarted}, {:run_rejoin, ^run_id, _, ^session}}
  end

  defp flush_sent do
    receive do
      {:sent, _, _} -> flush_sent()
    after
      0 -> :ok
    end
  end
end
