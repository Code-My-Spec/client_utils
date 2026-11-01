defmodule ClientUtils.RunLinkCookieTest do
  @moduledoc """
  A run boots with its harness's cookie (`-setcookie`), which under a packaged
  harness is the release's own, not the user's. `:peer` and every other node a
  test starts read the user's cookie file, so they were refused ("Invalid
  challenge reply") and timed out. A joined run keeps the harness's cookie for
  the harness alone and is otherwise back on the user's.

  Two BEAMs: this test as the harness, and the run, launched with a cookie
  file of its own in its home directory.
  """
  use ExUnit.Case, async: false

  @tag :tmp_dir
  test "a run started with its harness's cookie can start a peer node", ctx do
    File.write!(
      Path.join(ctx.tmp_dir, ".erlang.cookie"),
      "usercookie#{System.unique_integer([:positive])}"
    )

    File.chmod!(Path.join(ctx.tmp_dir, ".erlang.cookie"), 0o400)

    assert %{"event" => "peer", "result" => "ok"} = run(ctx)
  end

  @tag :tmp_dir
  test "with no cookie file to go back to, the run keeps its link", ctx do
    assert %{"event" => "peer"} = run(ctx)
  end

  defp run(ctx) do
    {_, 0} = System.cmd("epmd", ["-daemon"])
    tag = "cookie#{System.unique_integer([:positive])}"
    cookie = "harness#{System.unique_integer([:positive])}"
    listener = :"#{tag}_listener"
    run_id = System.unique_integer([:positive])

    {:ok, _} = Node.start(:"#{tag}_harness@127.0.0.1", :longnames)
    on_exit(fn -> Node.stop() end)
    Node.set_cookie(String.to_atom(cookie))
    Process.register(self(), listener)

    File.write!(Path.join(ctx.tmp_dir, "run.exs"), """
    link = ClientUtils.RunLink.join()

    result =
      try do
        {:ok, peer, node} =
          :peer.start(%{name: :#{tag}_peer, host: ~c"127.0.0.1", longnames: true, wait_boot: 15_000})

        ^node = :erpc.call(node, :erlang, :node, [])
        :peer.stop(peer)
        "ok"
      catch
        kind, reason -> inspect({kind, reason})
      end

    ClientUtils.RunLink.report(link, %{"event" => "peer", "result" => result})
    """)

    ebins = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

    port =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: Enum.flat_map(ebins, &["-pa", &1]) ++ ["run.exs"],
        cd: ctx.tmp_dir,
        env: [
          {~c"HOME", String.to_charlist(ctx.tmp_dir)},
          {~c"ELIXIR_ERL_OPTIONS", ~c"-hidden -name #{tag}_run@127.0.0.1 -setcookie #{cookie}"},
          {~c"CMS_HARNESS_NODE", Atom.to_charlist(node())},
          {~c"CMS_HARNESS_COOKIE", String.to_charlist(cookie)},
          {~c"CMS_RUN_ID", ~c"#{run_id}"},
          {~c"CMS_RUN_LISTENER", Atom.to_charlist(listener)}
        ]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", ["-9", "#{pid}"], stderr_to_stdout: true) end)

    events = collect(run_id, [], port)
    Enum.find(events, &(&1["event"] == "peer")) || flunk("no peer event in #{inspect(events)}")
  end

  # Adopts the run and acknowledges each event until its exit status.
  defp collect(run_id, events, port) do
    receive do
      {:run_rejoin, ^run_id, _node, session} ->
        send(session, {:run_adopted, run_id})
        collect(run_id, events, port)

      {:run_event, ^run_id, session, seq, %{"event" => "exit"}} ->
        send(session, {:run_ack, run_id, seq})
        Enum.reverse(events)

      {:run_event, ^run_id, session, seq, event} ->
        send(session, {:run_ack, run_id, seq})
        collect(run_id, [event | events], port)

      {^port, {:data, _}} ->
        collect(run_id, events, port)
    after
      40_000 -> flunk("the run went quiet after #{inspect(Enum.reverse(events))}")
    end
  end
end
