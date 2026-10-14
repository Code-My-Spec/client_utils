defmodule ClientUtils.TestFormatter.TestCacheLatestRunTest do
  use ExUnit.Case, async: false

  alias ClientUtils.TestFormatter.TestCache

  setup do
    previous = System.get_env("AGENT_TEST_EVENTS_FILE")
    dir = Path.join(System.tmp_dir!(), "latest-cache-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    System.put_env("AGENT_TEST_EVENTS_FILE", Path.join(dir, "events.json"))

    on_exit(fn ->
      restore_environment(previous)
      File.rm_rf!(dir)
    end)

    %{cutoff: ~U[2026-01-01 00:00:00Z]}
  end

  defp restore_environment(nil), do: System.delete_env("AGENT_TEST_EVENTS_FILE")
  defp restore_environment(value), do: System.put_env("AGENT_TEST_EVENTS_FILE", value)

  defp event(file, state),
    do: {:test_finished, %{name: :example, tags: %{file: file}, state: state}}

  test "a later pass replaces the failure in both replay readers", %{cutoff: cutoff} do
    failure = event("/a.exs", {:failed, []})
    pass = event("/a.exs", nil)
    TestCache.store_events([failure], [], DateTime.add(cutoff, 1, :second))
    TestCache.store_events([pass], [], DateTime.add(cutoff, 2, :second))

    assert TestCache.get_events_for_file("/a.exs", cutoff) == [pass]
    assert TestCache.get_events_after(cutoff) == [pass]
    assert TestCache.file_tested_after?("/a.exs", cutoff)
  end

  test "a later failure replaces a pass and keeps the complete run sequence", %{cutoff: cutoff} do
    pass = event("/a.exs", nil)

    latest = [
      {:test_started, %{tags: %{file: "/a.exs"}}},
      event("/a.exs", {:failed, []}),
      {:module_finished, %{file: "/a.exs"}}
    ]

    TestCache.store_events([pass], [], DateTime.add(cutoff, 1, :second))
    TestCache.store_events(latest, [], DateTime.add(cutoff, 2, :second))

    assert TestCache.get_events_for_file("/a.exs", cutoff) == latest
    assert TestCache.get_events_after(cutoff) == latest
  end

  test "rerunning one file preserves another file's failure", %{cutoff: cutoff} do
    first = event("/a.exs", {:failed, []})
    other = event("/b.exs", {:failed, []})
    pass = event("/a.exs", nil)
    TestCache.store_events([first, other], [], DateTime.add(cutoff, 1, :second))
    TestCache.store_events([pass], [], DateTime.add(cutoff, 2, :second))

    assert TestCache.get_events_after(cutoff) == [pass, other]
    assert TestCache.get_events_for_file("/b.exs", cutoff) == [other]
  end

  test "completion time wins over insertion order", %{cutoff: cutoff} do
    pass = event("/a.exs", nil)
    failure = event("/a.exs", {:failed, []})
    TestCache.store_events([pass], [], DateTime.add(cutoff, 2, :second))
    TestCache.store_events([failure], [], DateTime.add(cutoff, 1, :second))

    assert TestCache.get_events_for_file("/a.exs", cutoff) == [pass]
  end

  test "equal timestamps use the last appended run", %{cutoff: cutoff} do
    completed = DateTime.add(cutoff, 1, :second)
    pass = event("/a.exs", nil)
    TestCache.store_events([event("/a.exs", {:failed, []})], [], completed)
    TestCache.store_events([pass], [], completed)

    assert TestCache.get_events_for_file("/a.exs", cutoff) == [pass]
  end

  test "the cutoff remains exclusive and absent files remain uncovered", %{cutoff: cutoff} do
    TestCache.store_events([event("/a.exs", nil)], [], cutoff)

    assert TestCache.get_events_for_file("/a.exs", cutoff) == []
    assert TestCache.get_events_after(cutoff) == []
    refute TestCache.file_tested_after?("/a.exs", cutoff)
    refute TestCache.file_tested_after?("/missing.exs", cutoff)
  end
end
