defmodule ClientUtils.TestFormatter.TestCache do
  @moduledoc """
  Caches test events to a JSON file, keyed by file.
  Callers can query: "was file X tested after time Y?"

  Uses JSON files for persistent storage that can be shared between
  separate Erlang VM instances.

  Events are stored as base64-encoded Erlang terms to preserve
  all type information (tuples, structs, etc).
  """

  @default_base_dir ".code_my_spec/internal"
  @default_events_filename "agent_test_events.json"

  @doc """
  Returns the events file path.
  Uses the configured :agent_test_dir, or can be overridden via AGENT_TEST_EVENTS_FILE environment variable.
  """
  def events_file do
    case System.get_env("AGENT_TEST_EVENTS_FILE") do
      nil ->
        dir = Application.get_env(:client_utils, :agent_test_dir, @default_base_dir)
        Path.join(dir, @default_events_filename)

      path ->
        path
    end
  end

  @doc """
  No-op for compatibility. JSON files don't need setup.
  """
  def ensure_started, do: :ok

  @doc """
  No-op for compatibility. JSON files don't need setup.
  """
  def setup, do: :ok

  @doc """
  Stores a batch of events to the JSON file as a new run.
  `for_callers` is a list of PIDs (as strings) that this run is for.
  """
  def store_events(events, for_callers \\ [], tested_at \\ DateTime.utc_now()) do
    data = read_events_file()

    new_run = %{
      "completed_at" => DateTime.to_iso8601(tested_at),
      "for_callers" => for_callers,
      "events" =>
        events
        |> Enum.map(fn event ->
          file = extract_file(event)

          %{
            "file" => file,
            "event" => encode_event(event)
          }
        end)
        |> Enum.filter(fn %{"file" => file} -> file != nil end)
    }

    updated_data = %{data | "runs" => data["runs"] ++ [new_run]}
    write_events_file(updated_data)

    :ok
  end

  @doc """
  Gets all events for a file that were recorded after the given time.
  """
  def get_events_for_file(file, after_time) do
    data = read_events_file()
    after_timestamp = to_unix(after_time)

    data["runs"]
    |> Enum.filter(fn run ->
      run_timestamp = run["completed_at"] |> parse_iso8601() |> to_unix()
      run_timestamp > after_timestamp
    end)
    |> Enum.flat_map(fn run -> run["events"] end)
    |> Enum.filter(fn %{"file" => f} -> f == file end)
    |> Enum.map(fn %{"event" => encoded} -> decode_event(encoded) end)
  end

  @doc """
  Gets all events from runs completed after the given time.
  """
  def get_events_after(after_time) do
    data = read_events_file()
    after_timestamp = to_unix(after_time)

    data["runs"]
    |> Enum.filter(fn run ->
      run_timestamp = run["completed_at"] |> parse_iso8601() |> to_unix()
      run_timestamp > after_timestamp
    end)
    |> Enum.flat_map(fn run -> run["events"] end)
    |> Enum.map(fn %{"event" => encoded} -> decode_event(encoded) end)
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
  If files is empty, returns true (vacuous truth).
  """
  def files_tested_after?([], _requested_at), do: true

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
  Returns a summary of all cached files with their timestamps.
  Useful for debugging. Returns a list of {file, min_timestamp, max_timestamp, event_count}.
  """
  def list_cached_files do
    data = read_events_file()

    data["runs"]
    |> Enum.flat_map(fn run ->
      completed_at = run["completed_at"]

      run["events"]
      |> Enum.map(fn %{"file" => file} -> {file, completed_at} end)
    end)
    |> Enum.group_by(fn {file, _} -> file end, fn {_, ts} -> ts end)
    |> Enum.map(fn {file, timestamps} ->
      {file, Enum.min(timestamps), Enum.max(timestamps), length(timestamps)}
    end)
    |> Enum.sort()
  end

  @doc """
  Clears all cached events.
  """
  def clear do
    write_events_file(%{"runs" => []})
  end

  @doc """
  Deletes the events file entirely. Useful for cleanup.
  """
  def destroy do
    file = events_file()

    if File.exists?(file) do
      File.rm!(file)
    end

    :ok
  end

  @doc """
  No-op for compatibility. JSON files don't need closing.
  """
  def close, do: :ok

  # Private functions

  defp read_events_file do
    file = events_file()

    case File.read(file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} when is_map(data) -> ensure_structure(data)
          _ -> %{"runs" => []}
        end

      {:error, _} ->
        %{"runs" => []}
    end
  end

  defp write_events_file(data) do
    file = events_file()
    dir = Path.dirname(file)
    tmp_file = file <> ".tmp"

    # Ensure directory exists
    File.mkdir_p!(dir)

    # Atomic write: write to temp file, then rename
    File.write!(tmp_file, Jason.encode!(data, pretty: true))
    File.rename!(tmp_file, file)
  end

  defp ensure_structure(data) do
    %{"runs" => data["runs"] || []}
  end

  defp encode_event(event) do
    event
    |> :erlang.term_to_binary()
    |> Base.encode64()
  end

  defp decode_event(encoded) do
    encoded
    |> Base.decode64!()
    |> :erlang.binary_to_term()
  end

  defp parse_iso8601(iso_string) do
    {:ok, datetime, _} = DateTime.from_iso8601(iso_string)
    datetime
  end

  defp to_unix(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)
  defp to_unix(unix) when is_integer(unix), do: unix
end
