defmodule ClientUtils.Harness.Onboarding.FileIO do
  @moduledoc """
  The default way onboarding touches a working copy: the real filesystem.

  Onboarding is mostly decisions, but it has to write four or five things, and
  the code that decides should not have to know how. This is the plain answer —
  `File` and `System.cmd/3`, rooted at a directory — and it is what a generated
  application gets without configuring anything.

  Its handle is the root, because a directory is all this needs. A host with its
  own filesystem abstraction passes `{ThatModule, handle}` instead; the callback
  names here are `CodeMySpec.Environments`' names precisely so that host writes
  no adapter — see `ClientUtils.Harness.Onboarding.Port`.
  """

  @behaviour ClientUtils.Harness.Onboarding.IO

  @impl true
  def read_file(root, path) do
    case File.read(Path.join(root, path)) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def write_file(root, path, contents) do
    full = Path.join(root, path)

    with :ok <- File.mkdir_p(Path.dirname(full)) do
      File.write(full, contents)
    end
  end

  # Not an `@impl`: `chmod/3` is optional on the port, because a host writing
  # through a channel and an in-memory adapter have no local inode to restrict.
  # This adapter is the real filesystem, so it is the one that can.
  @spec chmod(String.t(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def chmod(root, path, mode), do: File.chmod(Path.join(root, path), mode)

  @impl true
  def file_exists?(root, path), do: File.exists?(Path.join(root, path))

  # The port supplies `stderr_to_stdout: true`; `cd` is this adapter's own, the
  # root being its whole state.
  @impl true
  def cmd(root, command, args, opts \\ []) do
    System.cmd(command, args, Keyword.merge(opts, cd: root))
  rescue
    # A missing binary raises rather than returning non-zero, and onboarding
    # treats "could not run it" the same as "it refused" — both mean the step did
    # not happen, and neither is worth aborting the whole command over.
    e in ErlangError -> {Exception.message(e), 1}
  end
end
