defmodule ClientUtils.RunLinkTest do
  use ExUnit.Case

  alias ClientUtils.RunLink

  test "a run without a stream halts when its harness goes away" do
    assert RunLink.on_harness_lost(false) == :halt
  end

  test "a run with a stream carries on when its harness goes away" do
    assert RunLink.on_harness_lost(true) == :continue
  end

  test "a run that outlives its owner stops reporting to it" do
    Process.register(self(), :run_link_test_listener)

    link = %RunLink{
      harness: node(),
      listener: :run_link_test_listener,
      run_id: System.unique_integer([:positive])
    }

    owner = spawn(fn -> Process.sleep(:infinity) end)
    watcher = RunLink.watch(owner, link, true)
    ref = Process.monitor(watcher)

    RunLink.report(link, %{"event" => "test"})
    assert_received {:run_event, _, %{"event" => "test"}}

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^watcher, :normal}

    RunLink.report(link, %{"event" => "test"})
    refute_received {:run_event, _, _}
  end
end
