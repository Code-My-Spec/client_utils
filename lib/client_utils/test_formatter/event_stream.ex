defmodule ClientUtils.TestFormatter.EventStream do
  @moduledoc """
  A run's durable record of its events, for the harness that started it to
  re-attach to after a restart: one JSON object per line, appended to the
  file named by `CMS_RUN_EVENT_STREAM`.

  Every line has `event` and `seq`, which strictly increases within the file,
  and, in a shard of a run (`CMS_RUN_SHARD`, `CMS_RUN_SHARDS`), `shard` and
  `shards`. `suite_finished` carries this process's totals.
  """

  require Logger

  defstruct [:file, :path, seq: 0, shard: %{}, totals: %{}]

  @type t :: %__MODULE__{}

  @totals %{"pass" => 0, "fail" => 0, "skip" => 0, "excluded" => 0, "invalid" => 0}

  @counted %{
    "test_passed" => "pass",
    "test_failed" => "fail",
    "test_skipped" => "skip",
    "test_excluded" => "excluded",
    "test_invalid" => "invalid"
  }

  @doc """
  Open the stream the environment names, or `nil` when it names none.

  The variable is removed once read: a test that shells out to `mix test`
  would otherwise append its own run to this one's stream.
  """
  @spec open() :: t() | nil
  def open do
    path = System.get_env("CMS_RUN_EVENT_STREAM")
    System.delete_env("CMS_RUN_EVENT_STREAM")
    open(path)
  end

  @spec open(String.t() | nil) :: t() | nil
  def open(blank) when blank in [nil, ""], do: nil

  def open(path) do
    File.mkdir_p!(Path.dirname(path))
    {seq, torn?} = resume(path)
    {:ok, file} = :file.open(path, [:append, :raw, :binary])
    # A line torn by a killed writer is closed off before the next is appended.
    if torn?, do: :file.write(file, "\n")

    %__MODULE__{file: file, path: path, seq: seq, shard: shard(), totals: @totals}
  end

  @doc """
  Append one event, written through to the file before returning. A run
  without a stream, or an event the stream does not record, writes nothing.
  """
  @spec write(t() | nil, map() | nil) :: t() | nil
  def write(nil, _event), do: nil
  def write(stream, nil), do: stream

  def write(%__MODULE__{} = stream, %{"event" => name} = event) do
    stream = %{stream | seq: stream.seq + 1, totals: count(stream.totals, name)}

    line =
      event
      |> Map.merge(if name == "suite_finished", do: stream.totals, else: %{})
      |> Map.merge(stream.shard)
      |> Map.put("seq", stream.seq)
      |> Jason.encode!()

    with {:error, reason} <- :file.write(stream.file, [line, ?\n]) do
      Logger.warning("Event stream write to #{stream.path} failed: #{inspect(reason)}")
    end

    stream
  end

  defp count(totals, name) do
    case @counted do
      %{^name => key} -> Map.update!(totals, key, &(&1 + 1))
      _ -> totals
    end
  end

  # Where a stream that already has lines carries on from: its last seq, and
  # whether its last line was cut short.
  defp resume(path) do
    case File.read(path) do
      {:ok, ""} -> {0, false}
      {:ok, content} -> {last_seq(content), not String.ends_with?(content, "\n")}
      {:error, _} -> {0, false}
    end
  end

  defp last_seq(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value(0, fn line ->
      case Jason.decode(line) do
        {:ok, %{"seq" => seq}} when is_integer(seq) -> seq
        _ -> nil
      end
    end)
  end

  defp shard do
    for {key, var} <- [{"shard", "CMS_RUN_SHARD"}, {"shards", "CMS_RUN_SHARDS"}],
        {n, ""} <- [Integer.parse(System.get_env(var) || "")],
        into: %{},
        do: {key, n}
  end
end
