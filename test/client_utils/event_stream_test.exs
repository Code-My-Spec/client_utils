defmodule ClientUtils.TestFormatter.EventStreamTest do
  use ExUnit.Case

  alias ClientUtils.TestFormatter

  @env ~w(CMS_RUN_EVENT_STREAM CMS_RUN_SHARD CMS_RUN_SHARDS)

  setup do
    saved = for name <- @env, into: %{}, do: {name, System.get_env(name)}

    on_exit(fn ->
      for {name, value} <- saved,
          do: if(value, do: System.put_env(name, value), else: System.delete_env(name))
    end)

    Enum.each(@env, &System.delete_env/1)
  end

  defp start(env) do
    System.put_env(env)
    {:ok, config} = TestFormatter.init([])
    GenServer.stop(config.cli_formatter)
    %{config | cli_formatter: spawn(fn -> Process.sleep(:infinity) end)}
  end

  defp run(config, events) do
    Enum.reduce(events, config, fn event, config ->
      {:noreply, config} = TestFormatter.handle_cast(event, config)
      config
    end)
  end

  defp lines(path), do: path |> File.read!() |> String.split("\n", trim: true)
  defp events(path), do: Enum.map(lines(path), &Jason.decode!/1)

  defp ex_test(name, state, line \\ 10) do
    %ExUnit.Test{
      name: :"test #{name}",
      module: MyApp.SomeTest,
      case: MyApp.SomeTest,
      state: state,
      time: 2_500,
      tags: %{file: __ENV__.file, line: line}
    }
  end

  defp suite do
    failure = [
      {:error, catch_error(raise "boom"), [{MyApp.SomeTest, :f, 1, file: ~c"x.ex", line: 3}]}
    ]

    [
      {:suite_started, []},
      {:test_started, ex_test("passes", nil)},
      {:test_finished, ex_test("passes", nil)},
      {:test_started, ex_test("fails", nil, 20)},
      {:test_finished, ex_test("fails", {:failed, failure}, 20)},
      {:test_finished, ex_test("skipped", {:skipped, "later"})},
      {:test_finished, ex_test("excluded", {:excluded, "tagged"})},
      {:test_finished, ex_test("invalid", {:invalid, MyApp.SomeTest})},
      {:suite_finished, %{run: 1_500, load: nil, async: nil}}
    ]
  end

  @tag :tmp_dir
  test "a run that names a stream appends each event to it", %{tmp_dir: dir} do
    path = Path.join(dir, "runs/1.jsonl")

    %{"CMS_RUN_EVENT_STREAM" => path} |> start() |> run(suite())

    assert [
             %{"event" => "suite_started", "seq" => 1},
             %{"event" => "test_started", "seq" => 2} = started,
             %{"event" => "test_passed", "seq" => 3} = passed,
             %{"event" => "test_started", "seq" => 4},
             %{"event" => "test_failed", "seq" => 5} = failed,
             %{"event" => "test_skipped", "seq" => 6},
             %{"event" => "test_excluded", "seq" => 7},
             %{"event" => "test_invalid", "seq" => 8} = invalid,
             %{"event" => "suite_finished", "seq" => 9} = finished
           ] = events(path)

    assert started == %{
             "event" => "test_started",
             "seq" => 2,
             "file" => "test/client_utils/event_stream_test.exs",
             "line" => 10,
             "name" => "passes",
             "module" => "MyApp.SomeTest"
           }

    assert passed ==
             Map.merge(started, %{"event" => "test_passed", "seq" => 3, "duration" => 2.5})

    assert %{"message" => "boom", "failure_line" => 20, "line" => 20, "name" => "fails"} = failed
    assert %{"message" => "setup_all failed", "failure_line" => 10} = invalid

    assert finished == %{
             "event" => "suite_finished",
             "seq" => 9,
             "pass" => 1,
             "fail" => 1,
             "skip" => 1,
             "excluded" => 1,
             "invalid" => 1,
             "duration" => 1.5
           }
  end

  @tag :tmp_dir
  test "a test its module's setup_all failed carries that failure", %{tmp_dir: dir} do
    path = Path.join(dir, "1.jsonl")
    reason = catch_error(raise "no database")
    module = %ExUnit.TestModule{name: MyApp.SomeTest, state: {:failed, [{:error, reason, []}]}}

    %{"CMS_RUN_EVENT_STREAM" => path}
    |> start()
    |> run([{:test_finished, ex_test("invalid", {:invalid, module})}])

    assert [%{"event" => "test_invalid", "message" => "no database", "failure_line" => 10}] =
             events(path)
  end

  @tag :tmp_dir
  test "a stream that already has lines is appended to, its seq carrying on", %{tmp_dir: dir} do
    path = Path.join(dir, "1.jsonl")
    File.write!(path, ~s({"event":"suite_started","seq":1}\n{"event":"test_started","seq":2}\n))

    %{"CMS_RUN_EVENT_STREAM" => path} |> start() |> run(Enum.take(suite(), 2))

    assert [
             ~s({"event":"suite_started","seq":1}),
             ~s({"event":"test_started","seq":2}),
             _,
             _
           ] = lines(path)

    assert Enum.map(events(path), & &1["seq"]) == [1, 2, 3, 4]
  end

  @tag :tmp_dir
  test "a line torn by a killed writer is closed off before the next", %{tmp_dir: dir} do
    path = Path.join(dir, "1.jsonl")
    File.write!(path, ~s({"event":"suite_started","seq":1}\n{"event":"test_st))

    %{"CMS_RUN_EVENT_STREAM" => path} |> start() |> run([{:suite_started, []}])

    assert [_, ~s({"event":"test_st), last] = lines(path)
    assert %{"event" => "suite_started", "seq" => 2} = Jason.decode!(last)
  end

  @tag :tmp_dir
  test "seq strictly increases across the file", %{tmp_dir: dir} do
    path = Path.join(dir, "1.jsonl")
    config = start(%{"CMS_RUN_EVENT_STREAM" => path})

    config |> run(suite()) |> run(suite())

    seqs = Enum.map(events(path), & &1["seq"])
    assert seqs == Enum.to_list(1..length(seqs))
  end

  @tag :tmp_dir
  test "a shard's events carry its shard and its own totals", %{tmp_dir: dir} do
    path = Path.join(dir, "shard-2.jsonl")

    %{"CMS_RUN_EVENT_STREAM" => path, "CMS_RUN_SHARD" => "2", "CMS_RUN_SHARDS" => "4"}
    |> start()
    |> run(suite())

    events = events(path)
    assert Enum.all?(events, &match?(%{"shard" => 2, "shards" => 4}, &1))
    assert %{"event" => "suite_finished", "pass" => 1, "fail" => 1} = List.last(events)
  end

  @tag :tmp_dir
  test "the stream's variable is not passed on to what the run starts", %{tmp_dir: dir} do
    start(%{"CMS_RUN_EVENT_STREAM" => Path.join(dir, "1.jsonl")})

    assert System.get_env("CMS_RUN_EVENT_STREAM") == nil
  end

  @tag :tmp_dir
  test "a run that names no stream writes none", %{tmp_dir: dir} do
    config = File.cd!(dir, fn -> %{} |> start() |> run(suite()) end)

    assert config.stream == nil
    assert File.ls!(dir) == []
  end

  @tag :tmp_dir
  test "a streamed run's CLI output failing does not take the formatter down", %{tmp_dir: dir} do
    System.put_env("CMS_RUN_EVENT_STREAM", Path.join(dir, "1.jsonl"))
    {:ok, streamed} = TestFormatter.init([])
    {:ok, plain} = TestFormatter.init([])
    {:links, links} = Process.info(self(), :links)

    refute streamed.cli_formatter in links
    assert plain.cli_formatter in links
  end
end
