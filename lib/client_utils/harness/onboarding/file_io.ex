defmodule ClientUtils.Harness.Onboarding.FileIO do
  @moduledoc """
  The default way onboarding touches a working copy: the real filesystem.

  Onboarding is mostly decisions, but it has to write four or five things, and
  the code that decides should not have to know how. This is the plain answer —
  `File` and `System.cmd/3`, rooted at a directory — and it is what a generated
  application gets without configuring anything.

  A host with its own filesystem abstraction passes its own module instead. That
  is not hypothetical: CodeMySpec routes every write through `Environments` so its
  specs can drive onboarding against an in-memory working copy, and without a seam
  here the only way to exercise onboarding at all is to build a real directory —
  temp dir, git repo, plugin tree — which is four fixtures standing in for one
  surface.
  """

  @behaviour ClientUtils.Harness.Onboarding.IO

  @impl true
  def read(root, path) do
    case File.read(Path.join(root, path)) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def write(root, path, contents) do
    full = Path.join(root, path)

    with :ok <- File.mkdir_p(Path.dirname(full)) do
      File.write(full, contents)
    end
  end

  @impl true
  def exists?(root, path), do: File.exists?(Path.join(root, path))

  @impl true
  def cmd(root, command, args) do
    System.cmd(command, args, cd: root, stderr_to_stdout: true)
  rescue
    # A missing binary raises rather than returning non-zero, and onboarding
    # treats "could not run it" the same as "it refused" — both mean the step did
    # not happen, and neither is worth aborting the whole command over.
    e in ErlangError -> {Exception.message(e), 1}
  end
end
