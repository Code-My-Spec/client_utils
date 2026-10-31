defmodule ClientUtils.RunLinkEnvTest do
  @moduledoc """
  What a run reads from its environment is its alone: once read, the
  variables are gone, so a run a test starts (a spex driving a fixture's
  suite) is not taken for one of this run's shards. The formatter still knows
  it is a shard.
  """
  # The OS environment is the process's, shared by every test.
  use ExUnit.Case, async: false

  alias ClientUtils.RunLink
  alias ClientUtils.TestFormatter

  @vars ~w(CMS_RUN_SHARD CMS_RUN_SHARDS CMS_HARNESS_NODE CMS_RUN_ID)

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    System.put_env(%{"CMS_RUN_SHARD" => "2", "CMS_RUN_SHARDS" => "4"})
    :ok
  end

  test "joining removes the shard's numbering from the environment" do
    assert RunLink.join() == nil

    assert System.get_env("CMS_RUN_SHARD") == nil
    assert System.get_env("CMS_RUN_SHARDS") == nil
  end

  test "the formatter still knows it is a shard" do
    {:ok, config} = TestFormatter.init([])
    GenServer.stop(config.cli_formatter)

    assert config.shard?
    assert System.get_env("CMS_RUN_SHARDS") == nil
  end
end
