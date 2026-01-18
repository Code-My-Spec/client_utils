defmodule ClientUtils.TestFormatter.TestCache do
  @moduledoc """
  Caches test events to DETS, keyed by file.
  Callers can query: "was file X tested after time Y?"

  Uses DETS for persistent storage that can be shared between
  separate Erlang VM instances (e.g., for distributed test scenarios).
  """

  @events_table :test_events
  @default_dets_file "agent_test_cache.dets"

  @doc """
  Returns the DETS file path.
  Can be configured via AGENT_TEST_CACHE_FILE environment variable.
  """
  def cache_file do
    System.get_env("AGENT_TEST_CACHE_FILE") || @default_dets_file
  end

  @doc """
  Ensures DETS table is open and ready.
  """
  def ensure_started do
    file = cache_file() |> String.to_charlist()

    case :dets.open_file(@events_table, file: file, type: :bag) do
      {:ok, @events_table} -> :ok
      {:error, {:already_open, @events_table}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Sets up DETS. Called during formatter init.
  """
  def setup do
    ensure_started()
  end

  @doc """
  Stores a batch of events to DETS, keyed by file and timestamp.
  """
  def store_events(events, tested_at \\ DateTime.utc_now()) do
    ensure_started()
    timestamp = to_unix(tested_at)

    for event <- events do
      file = extract_file(event)

      if file do
        :dets.insert(@events_table, {file, timestamp, event})
      end
    end

    :dets.sync(@events_table)
    :ok
  end

  @doc """
  Gets all events for a file that were recorded after the given time.
  """
  def get_events_for_file(file, after_time) do
    ensure_started()
    timestamp = to_unix(after_time)

    # Get all entries for this file
    entries = :dets.lookup(@events_table, file)

    # Filter to only those after the requested time and extract events
    entries
    |> Enum.filter(fn {_file, ts, _event} -> ts > timestamp end)
    |> Enum.map(fn {_file, _ts, event} -> event end)
  end

  @doc """
  Returns true if the file was tested after the given time.
  """
  def file_tested_after?(file, requested_at) do
    case get_events_for_file(file, requested_at) do
      [] -> false
      _ -> true
    end
  end

  @doc """
  Returns true if all files were tested after the given time.
  """
  def files_tested_after?(files, requested_at) do
    Enum.all?(files, &file_tested_after?(&1, requested_at))
  end

  @doc """
  Extracts the file path from a test event.
  """
  def extract_file(event) do
    case event do
      {:test_started, %{tags: %{file: file}}} -> file
      {:test_finished, %{tags: %{file: file}}} -> file
      {:module_started, %{file: file}} -> file
      {:module_finished, %{file: file}} -> file
      _ -> nil
    end
  end

  @doc """
  Clears all cached events.
  """
  def clear do
    ensure_started()
    :dets.delete_all_objects(@events_table)
    :dets.sync(@events_table)
  end

  @doc """
  Closes and deletes the DETS file entirely. Useful for test cleanup.
  """
  def destroy do
    :dets.close(@events_table)
    file = cache_file()

    if File.exists?(file) do
      File.rm!(file)
    end

    :ok
  end

  @doc """
  Closes the DETS table.
  """
  def close do
    :dets.close(@events_table)
  end

  # Convert DateTime to Unix timestamp (microseconds for precision)
  defp to_unix(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)
  defp to_unix(unix) when is_integer(unix), do: unix
end
