defmodule ClientUtils.RunLinkRedirectTest do
  use ExUnit.Case, async: true

  alias ClientUtils.RunLink

  # `redirect_output/1` moves every process whose group leader was `:user`. One
  # that exits between the listing and the move must not take the caller down.
  test "a process that exited before it could follow the new device is skipped" do
    {:ok, device} = StringIO.open("")
    gone = spawn(fn -> :ok end)
    ref = Process.monitor(gone)
    assert_receive {:DOWN, ^ref, :process, ^gone, _}

    assert RunLink.follow(gone, device) == :ok
  end

  test "a live process follows the new device" do
    {:ok, device} = StringIO.open("")
    live = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(live, :kill) end)

    assert RunLink.follow(live, device) == :ok
    assert Process.info(live, :group_leader) == {:group_leader, device}
  end
end
