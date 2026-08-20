defmodule ClientUtils.Harness.Onboarding.IO do
  @moduledoc """
  How onboarding reaches a working copy.

  Four operations, all scoped to the copy's directory, so the code that decides
  what a working copy needs never learns how the host stores it.
  `ClientUtils.Harness.Onboarding.FileIO` is the default and is what a generated
  application uses.

  Paths are always relative to the root and always use forward slashes.

  ## The names are borrowed, on purpose

  `read_file/2`, `write_file/3`, `file_exists?/2` and `cmd/4` are
  `CodeMySpec.Environments`' functions, with its arities and its return shapes.
  A host that already has a filesystem abstraction of this shape implements
  nothing — it passes `{ThatModule, handle}` as `io:` and is done. See
  `ClientUtils.Harness.Onboarding.Port` for why the port was renamed to fit a
  caller rather than the other way round.

  ## The first argument is a handle, not necessarily a path

  It is the bare root when `io:` is a plain module, and whatever the host paired
  with its module when `io:` is `{module, state}`. Treat it as opaque and match
  the shape you asked for.
  """

  @doc "Contents of `path`, or an error when it is not there."
  @callback read_file(handle :: term(), path :: String.t()) ::
              {:ok, String.t()} | {:error, term()}

  @doc "Write `contents` to `path`, creating parents."
  @callback write_file(handle :: term(), path :: String.t(), contents :: String.t()) ::
              :ok | {:error, term()}

  @doc "Whether `path` exists."
  @callback file_exists?(handle :: term(), path :: String.t()) :: boolean()

  @doc """
  Run `command` with `args`, returning `{output, exit_status}`.

  Never raises — a missing binary is `{message, non-zero}`. Onboarding treats a
  step that could not run the same as one that refused, and neither aborts the
  command.

  `opts` is always `[]` from here; it exists so the callback matches
  `CodeMySpec.Environments.cmd/4` exactly, which is what lets that module be
  passed as an adapter without a shim.
  """
  @callback cmd(handle :: term(), command :: String.t(), args :: [String.t()], opts :: keyword()) ::
              {String.t(), non_neg_integer()}
end
