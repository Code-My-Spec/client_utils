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

  # Caps how many runs are retained in the events file. Without a cap this file
  # is read-parsed-encoded-rewritten in full on every test run, so it grows
  # without bound (observed at 16+ MB in long-lived projects). 100 runs is
  # comfortably more than the module's own 60-second cache-validity window
  # (see Mix.Tasks.AgentTest) while keeping the file small. Override via
  # `config :client_utils, :max_test_runs, N`.
  @max_runs 100

  # Caps the file's size on disk, which the run cap above does not.
  #
  # `@max_runs` bounds how many runs are retained and says nothing about how big
  # one is. A run carries one entry per test event, each a base64-encoded Erlang
  # term, so a large suite makes a large run and the count cap lets a hundred of
  # them through. Observed at 49 MB in one working copy and 5.8 MB in another on
  # 2026-09-03, on a machine that then filled its disk — which took Postgres
  # down, left the server answering 500, and dropped every harness channel. The
  # stop hook reported a connection problem, because that is the layer it can
  # see.
  #
  # Override via `config :client_utils, :max_test_events_bytes, N`.
  @max_bytes 100 * 1024 * 1024

  # `{"runs":[]}` — counted so the budget is the size of the file rather than of
  # its contents.
  @envelope_bytes 11

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

    max_runs = Application.get_env(:client_utils, :max_test_runs, @max_runs)
    # Runs are appended to the end, so the most recent run is last; keep the
    # tail so the cap always drops the oldest runs, never the newest.
    updated_runs = Enum.take(data["runs"] ++ [new_run], -max_runs)
    updated_data = %{data | "runs" => updated_runs}
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

    # Enforced here rather than in `store_events/3` so it holds for every caller
    # and every path into this file: past this point it physically cannot exceed
    # the budget.
    max_bytes = Application.get_env(:client_utils, :max_test_events_bytes, @max_bytes)
    data = %{data | "runs" => trim_to_budget(data["runs"] || [], max_bytes)}

    File.mkdir_p!(dir)
    File.write!(file, Jason.encode!(data))
  end

  # Newest runs win, for the same reason the count cap keeps the tail: the
  # question this file answers is "was X tested recently", so the oldest run is
  # always the one worth losing.
  #
  # Each run is sized once rather than re-encoding the whole file after every
  # drop, which would be quadratic in the number of runs — and this runs at the
  # end of every test suite.
  defp trim_to_budget(runs, max_bytes) do
    runs
    |> Enum.reverse()
    |> Enum.reduce_while({[], @envelope_bytes}, fn run, {kept, total} ->
      # +1 for the comma this run adds to the array.
      size = byte_size(Jason.encode!(run)) + 1

      cond do
        # The newest run alone is over budget. Nothing else can be kept either,
        # so stop here rather than walking the rest.
        kept == [] and total + size > max_bytes ->
          {:halt, {[drop_events(run)], total}}

        total + size > max_bytes ->
          {:halt, {kept, total}}

        true ->
          {:cont, {[run | kept], total + size}}
      end
    end)
    |> elem(0)
  end

  # A single run bigger than the whole budget. Its events cannot be kept; the
  # run is, because dropping the record outright would leave no trace a suite
  # ran at all, and `file_tested_after?/2` cannot tell "this run was discarded"
  # from "this run never happened".
  #
  # The consequence is deliberate: every file in a dropped run reads as
  # untested, so a stop hook blocks rather than allowing on evidence that no
  # longer exists. Failing toward "prove it again" is the safe direction, and
  # `events_dropped` is there so anyone reading the file can see why.
  defp drop_events(run) do
    run
    |> Map.put("events", [])
    |> Map.put("events_dropped", true)
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
