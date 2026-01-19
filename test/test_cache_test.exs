defmodule ClientUtils.TestFormatter.TestCacheTest do
  use ExUnit.Case

  alias ClientUtils.TestFormatter.TestCache

  setup do
    TestCache.clear()

    on_exit(fn ->
      TestCache.destroy()
    end)

    :ok
  end

  describe "extract_file/1" do
    test "extracts file from test_started event" do
      event = {:test_started, %{tags: %{file: "/path/to/test.exs"}}}
      assert TestCache.extract_file(event) == "/path/to/test.exs"
    end

    test "extracts file from test_finished event" do
      event = {:test_finished, %{tags: %{file: "/path/to/test.exs"}}}
      assert TestCache.extract_file(event) == "/path/to/test.exs"
    end

    test "extracts file from module_started event" do
      event = {:module_started, %{file: "/path/to/test.exs"}}
      assert TestCache.extract_file(event) == "/path/to/test.exs"
    end

    test "extracts file from module_finished event" do
      event = {:module_finished, %{file: "/path/to/test.exs"}}
      assert TestCache.extract_file(event) == "/path/to/test.exs"
    end

    test "returns nil for events without file" do
      assert TestCache.extract_file({:suite_started, %{}}) == nil
      assert TestCache.extract_file({:suite_finished, %{}}) == nil
    end
  end

  describe "store_events/2 and get_events_for_file/2" do
    test "stores and retrieves events by file" do
      file = "/path/to/test.exs"
      before_time = DateTime.utc_now()
      Process.sleep(10)

      events = [
        {:test_started, %{tags: %{file: file}}},
        {:test_finished, %{tags: %{file: file}}}
      ]

      TestCache.store_events(events)

      retrieved = TestCache.get_events_for_file(file, before_time)
      assert length(retrieved) == 2
    end

    test "does not return events from before the requested time" do
      file = "/path/to/test.exs"

      events = [{:test_started, %{tags: %{file: file}}}]
      TestCache.store_events(events)

      Process.sleep(10)
      after_time = DateTime.utc_now()

      retrieved = TestCache.get_events_for_file(file, after_time)
      assert retrieved == []
    end

    test "returns empty list for non-existent file" do
      before_time = DateTime.utc_now()
      retrieved = TestCache.get_events_for_file("/nonexistent/file.exs", before_time)
      assert retrieved == []
    end
  end

  describe "file_tested_after?/2" do
    test "returns true if file was tested after the given time" do
      file = "/path/to/test.exs"
      before_time = DateTime.utc_now()
      Process.sleep(10)

      events = [{:test_finished, %{tags: %{file: file}}}]
      TestCache.store_events(events)

      assert TestCache.file_tested_after?(file, before_time) == true
    end

    test "returns false if file was not tested after the given time" do
      file = "/path/to/test.exs"

      events = [{:test_finished, %{tags: %{file: file}}}]
      TestCache.store_events(events)

      Process.sleep(10)
      after_time = DateTime.utc_now()

      assert TestCache.file_tested_after?(file, after_time) == false
    end

    test "returns false for non-existent file" do
      before_time = DateTime.utc_now()
      assert TestCache.file_tested_after?("/nonexistent/file.exs", before_time) == false
    end
  end

  describe "files_tested_after?/2" do
    test "returns true if all files were tested after the given time" do
      file1 = "/path/to/test1.exs"
      file2 = "/path/to/test2.exs"
      before_time = DateTime.utc_now()
      Process.sleep(10)

      events = [
        {:test_finished, %{tags: %{file: file1}}},
        {:test_finished, %{tags: %{file: file2}}}
      ]

      TestCache.store_events(events)

      assert TestCache.files_tested_after?([file1, file2], before_time) == true
    end

    test "returns false if any file was not tested after the given time" do
      file1 = "/path/to/test1.exs"
      file2 = "/path/to/test2.exs"
      before_time = DateTime.utc_now()
      Process.sleep(10)

      # Only store events for file1
      events = [{:test_finished, %{tags: %{file: file1}}}]
      TestCache.store_events(events)

      assert TestCache.files_tested_after?([file1, file2], before_time) == false
    end

    test "returns true for empty file list" do
      before_time = DateTime.utc_now()
      assert TestCache.files_tested_after?([], before_time) == true
    end
  end

  describe "clear/0" do
    test "removes all cached events" do
      file = "/path/to/test.exs"
      before_time = DateTime.utc_now()
      Process.sleep(10)

      events = [{:test_finished, %{tags: %{file: file}}}]
      TestCache.store_events(events)

      assert TestCache.file_tested_after?(file, before_time) == true

      TestCache.clear()

      assert TestCache.file_tested_after?(file, before_time) == false
    end
  end
end
