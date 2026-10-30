defmodule ClientUtils.RunLinkSurvivalTest do
  @moduledoc """
  A linked run outlives the harness BEAM that launched it, with no shell in
  between, and a harness that comes up afterwards under another node name gets
  everything the first never acknowledged, then the run's exit.

  Three BEAMs: a harness that launches the run straight from a port, the run,
  and this test, which kills the first harness and stands in for the next one.
  """
  use ExUnit.Case, async: false

  @lines 15

  @tag :tmp_dir
  test "the run carries on when its harness is killed and reports to the next one", ctx do
    {_, 0} = System.cmd("epmd", ["-daemon"])
    tag = "survival#{System.unique_integer([:positive])}"
    cookie = "c#{System.unique_integer([:positive])}"
    listener = :"#{tag}_listener"
    run_id = System.unique_integer([:positive])
    files = Map.new(~w(output events run_pid), &{&1, Path.join(ctx.tmp_dir, &1)})

    write_scripts(ctx.tmp_dir, tag, cookie, listener, run_id, files)

    harness =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :exit_status,
        args: ["--name", "#{tag}_harness_1@127.0.0.1", "--cookie", cookie, "harness.exs"],
        cd: ctx.tmp_dir
      ])

    {:os_pid, harness_pid} = Port.info(harness, :os_pid)
    on_exit(fn -> System.cmd("kill", ["-9", "#{harness_pid}"], stderr_to_stdout: true) end)

    assert eventually(fn -> acked_by_first(files) >= 3 end), "the first harness heard nothing"
    run_pid = files["run_pid"] |> File.read!() |> String.trim()
    on_exit(fn -> System.cmd("kill", ["-9", run_pid], stderr_to_stdout: true) end)

    # Killed outright, as a crashed harness: nothing of it runs any cleanup.
    {_, 0} = System.cmd("kill", ["-9", "#{harness_pid}"])
    assert_receive {^harness, {:exit_status, _}}, 5_000
    assert alive?(run_pid), "the run died with the harness that launched it"
    first_acked = acked_by_first(files)

    # The next harness, a new node name under the same prefix.
    {:ok, _} = Node.start(:"#{tag}_harness_2@127.0.0.1", :longnames)
    on_exit(fn -> Node.stop() end)
    Node.set_cookie(String.to_atom(cookie))
    Process.register(self(), listener)

    assert_receive {:run_rejoin, ^run_id, _node, session}, 10_000
    send(session, {:run_adopted, run_id})
    events = collect(session, run_id, [])

    # Everything after what the first harness acknowledged, then the exit
    # status. The last one it wrote down may not have been acknowledged before
    # it was killed, so the replay starts there or just after.
    assert [{from, _} | _] = events
    assert from in [first_acked, first_acked + 1]
    assert Enum.map(events, &elem(&1, 0)) == Enum.to_list(from..(@lines + 1))
    assert {_, %{"event" => "exit", "status" => 0}} = List.last(events)

    assert eventually(fn -> not alive?(run_pid) end), "the run never exited after its ack"

    output = File.read!(files["output"])
    for i <- 1..@lines, do: assert(output =~ "line #{i}\n", "line #{i} lost: #{output}")
  end

  defp collect(session, run_id, events) do
    receive do
      {:run_event, ^run_id, _session, seq, %{"event" => "exit"} = event} ->
        send(session, {:run_ack, run_id, seq})
        Enum.reverse([{seq, event} | events])

      {:run_event, ^run_id, _session, seq, event} ->
        send(session, {:run_ack, run_id, seq})
        collect(session, run_id, [{seq, event} | events])
    after
      15_000 -> flunk("the run stopped reporting after #{inspect(Enum.reverse(events))}")
    end
  end

  defp acked_by_first(files) do
    case File.read(files["events"]) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> length()
      _ -> 0
    end
  end

  defp alive?(pid), do: match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))

  defp write_scripts(dir, tag, cookie, listener, run_id, files) do
    ebins = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

    File.write!(Path.join(dir, "run.exs"), """
    link = ClientUtils.RunLink.join()

    for i <- 1..#{@lines} do
      IO.puts("line \#{i}")
      ClientUtils.RunLink.report(link, %{"event" => "test", "name" => "t\#{i}"})
      Process.sleep(200)
    end
    """)

    # Acknowledges each event it hears and writes it down, and never exits.
    File.write!(Path.join(dir, "harness.exs"), """
    Process.register(self(), #{inspect(listener)})

    port =
      Port.open({:spawn_executable, #{inspect(System.find_executable("elixir"))}}, [
        :binary,
        :exit_status,
        args: Enum.flat_map(#{inspect(ebins)}, &["-pa", &1]) ++ ["run.exs"],
        env: [
          {~c"ELIXIR_ERL_OPTIONS", ~c"-hidden -name #{tag}_run@127.0.0.1 -setcookie #{cookie}"},
          {~c"CMS_HARNESS_NODE", Atom.to_charlist(node())},
          {~c"CMS_RUN_ID", ~c"#{run_id}"},
          {~c"CMS_RUN_LISTENER", ~c"#{listener}"},
          {~c"CMS_RUN_OUTPUT", ~c"#{files["output"]}"}
        ]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    File.write!(#{inspect(files["run_pid"])}, Integer.to_string(pid))

    loop = fn loop, session ->
      receive do
        {:run_rejoin, id, _node, session} ->
          send(session, {:run_adopted, id})
          loop.(loop, session)

        {:run_event, id, _session, seq, _event} ->
          File.write!(#{inspect(files["events"])}, "\#{seq}\\n", [:append])
          send(session, {:run_ack, id, seq})
          loop.(loop, session)

        _ ->
          loop.(loop, session)
      end
    end

    loop.(loop, nil)
    """)
  end

  defp eventually(fun, attempts \\ 300) do
    Enum.any?(1..attempts, fn _ ->
      fun.() or
        (
          Process.sleep(50)
          false
        )
    end)
  end
end
