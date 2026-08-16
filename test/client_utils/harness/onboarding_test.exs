defmodule ClientUtils.Harness.OnboardingTest do
  @moduledoc """
  Which databases a working copy is told to create.

  This list is the only thing that tells anyone a database exists, and nothing
  creates them on its own — the harness names databases and does not manage
  them, after a version that shelled out to `mix` with `MIX_ENV` scrubbed and
  emptied dev three times on 2026-08-13. So a partition missing from here is a
  database nobody is told to create, met later as "database does not exist" by
  whichever run needed it.

  Three, and the third is the newest. `mix harness.onboard` records
  `MIX_TEST_PARTITION` in `.claude/settings.local.json`'s `env` block so
  `resolve_partition!/2` can read it back, and Claude Code exports that block
  into the agent's session — so the agent's own `mix test` and the analyzer's
  exunit run resolved to the same name. Two full suites in one database, live
  every time someone tested during a sweep.

  The composition is pinned separately from the set because it has been wrong on
  its own: an earlier version wrote `_test_`, so the printed name and the
  database its own command created differed by one character, and the output was
  only ever compared to itself (c4a2acae).
  """

  use ExUnit.Case, async: true

  alias ClientUtils.Harness.Onboarding

  @partition "h1a2b3c4d"

  defp dbs, do: Onboarding.databases(@partition, :my_app)

  test "every suite that runs concurrently gets its own database" do
    assert Enum.map(dbs(), & &1.partition) == [
             @partition,
             @partition <> "s",
             @partition <> "a"
           ]
  end

  test "the analyzer's exunit run does not share the interactive session's database" do
    interactive = Enum.find(dbs(), &(&1.partition == @partition))
    analyzer_exunit = Enum.find(dbs(), &(&1.partition == @partition <> "a"))

    assert analyzer_exunit,
           "without this the agent's `mix test` and the analyzer's exunit run " <>
             "resolve to one database, which is two suites truncating under each other"

    refute interactive.name == analyzer_exunit.name
  end

  test "the name has no separator before the partition" do
    # `config/test.exs` composes "<app>_test<partition>". A separator here makes
    # the printed name and the database its own command creates differ.
    assert Enum.map(dbs(), & &1.name) == [
             "my_app_testh1a2b3c4d",
             "my_app_testh1a2b3c4ds",
             "my_app_testh1a2b3c4da"
           ]
  end

  test "each command names its own partition" do
    # The migration guard once printed `MIX_ENV=test mix ecto.migrate` while
    # checking a partition that command never touches. An agent followed it
    # correctly and nothing changed.
    for db <- dbs() do
      assert db.create =~ "MIX_TEST_PARTITION=#{db.partition} "
      assert db.migrate =~ "MIX_TEST_PARTITION=#{db.partition} "
    end
  end
end
