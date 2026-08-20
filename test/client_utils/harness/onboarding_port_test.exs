defmodule ClientUtils.Harness.Onboarding.PortTest do
  @moduledoc """
  The port dispatches to a plain module and to a `{module, state}` pair.

  The stateful form is the one that did not exist, and its absence is why this
  port went a week unused while `c570d32` reported the integration as done: a
  host whose filesystem abstraction is an object — CodeMySpec's `:memory`
  environment holds an `Agent` pid — could not be reached by an adapter given
  only a root string.

  The names asserted here are `CodeMySpec.Environments`' names, deliberately.
  That is what lets a caller pass `{ThatModule, handle}` and write no adapter,
  so a test that let them drift would give the renaming back its cost.
  """
  use ExUnit.Case, async: true

  alias ClientUtils.Harness.Onboarding.Port

  defmodule Stateful do
    @moduledoc false
    @behaviour ClientUtils.Harness.Onboarding.IO

    # The handle is an arbitrary term the port never inspects. An Agent is the
    # real case; a map is enough to prove it arrives intact.
    @impl true
    def read_file(%{store: store}, path), do: {:ok, "#{store}:#{path}"}

    @impl true
    def write_file(%{store: store}, path, contents),
      do: send(self(), {store, path, contents}) && :ok

    @impl true
    def file_exists?(%{store: store}, path), do: path == store

    @impl true
    def cmd(%{store: store}, command, args, opts),
      do: {"#{store} #{command} #{Enum.join(args, " ")} #{inspect(opts)}", 0}
  end

  defmodule Stateless do
    @moduledoc false
    @behaviour ClientUtils.Harness.Onboarding.IO

    @impl true
    def read_file(root, path), do: {:ok, "#{root}|#{path}"}

    @impl true
    def write_file(root, path, contents), do: send(self(), {root, path, contents}) && :ok

    @impl true
    def file_exists?(root, path), do: path == root

    @impl true
    def cmd(root, command, args, opts),
      do: {"#{root} #{command} #{Enum.join(args, " ")} #{inspect(opts)}", 0}
  end

  describe "a plain module" do
    test "receives the root as its handle" do
      assert Port.read(Stateless, "/root", "a.txt") == {:ok, "/root|a.txt"}
      assert Port.exists?(Stateless, "/root", "/root")
      assert Port.write(Stateless, "/root", "a.txt", "x") == :ok
      assert_received {"/root", "a.txt", "x"}
    end
  end

  describe "a {module, state} pair" do
    test "receives the state instead, and the root never reaches it" do
      io = {Stateful, %{store: "mem"}}

      assert Port.read(io, "/root", "a.txt") == {:ok, "mem:a.txt"}
      assert Port.exists?(io, "/root", "mem")
      refute Port.exists?(io, "/root", "/root")

      assert Port.write(io, "/root", "a.txt", "x") == :ok
      assert_received {"mem", "a.txt", "x"}
    end

    test "dispatches to the module it names" do
      assert Port.module({Stateful, :anything}) == Stateful
      assert Port.module(Stateless) == Stateless
    end
  end

  # Options are the port's, not the caller's: onboarding has nothing to say
  # about how a command runs except that its stderr belongs in the output it
  # judges, not in the caller's terminal. Passed explicitly rather than left to
  # a default argument, because a behaviour's callback has no defaults.
  describe "cmd" do
    test "supplies the options, both shapes" do
      assert {"/root git config a b [stderr_to_stdout: true]", 0} =
               Port.cmd(Stateless, "/root", "git", ["config", "a", "b"])

      assert {"mem git config a b [stderr_to_stdout: true]", 0} =
               Port.cmd({Stateful, %{store: "mem"}}, "/root", "git", ["config", "a", "b"])
    end
  end
end
