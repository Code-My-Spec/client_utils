defmodule ClientUtils.Harness.Onboarding.Port do
  @moduledoc """
  Calls an `io:` adapter — a module, or a module paired with the thing it acts on.

  ## Why the names are what they are

  These four operations are `read_file/2`, `write_file/3`, `file_exists?/2` and
  `cmd/4` because that is `CodeMySpec.Environments`' contract, verbatim. A host
  that already has a filesystem abstraction passes `{ThatModule, its_handle}`
  and writes no adapter at all — CodeMySpec passes
  `{CodeMySpec.Environments, env}`.

  The port used to name them `read/2`, `write/3`, `exists?/2`, `cmd/3` and take
  a bare root, which had two consequences. A host with state could not use it:
  CodeMySpec's specs drive a `:memory` environment holding an `Agent` pid in
  `ref`, and no adapter given only a path can find that agent — so the single
  case this port was justified by ("CodeMySpec passes an adapter over its own
  `Environments`", written into `c570d32` as though it were already true) was
  the one it could not serve, and CodeMySpec kept a second implementation of
  `onboard/2` and `check/2` instead. And a host without state still had to write
  a translation module whose whole content was renaming `read` to `read_file`.

  Naming the port after an interface a caller already implements costs this
  library nothing — its own `FileIO` is the only other implementation and it is
  ours to shape — and costs the caller nothing at all, which is the point.

  ## The shapes

    * `{module, state}` — `module.read_file(state, path)`. The state is opaque
      here; it is whatever the host needs and is passed straight back.
    * `module` — `module.read_file(root, path)`. The root is the state, which is
      all `FileIO` has ever needed.

  A generated application passes neither and gets `FileIO`.
  """

  @typedoc "An adapter: a module, or a module with the handle it acts on."
  @type t :: module() | {module(), term()}

  @spec read(t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def read(io, root, path), do: call(io, root, :read_file, [path])

  @spec write(t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def write(io, root, path, contents), do: call(io, root, :write_file, [path, contents])

  @spec exists?(t(), String.t(), String.t()) :: boolean()
  def exists?(io, root, path), do: call(io, root, :file_exists?, [path])

  # `stderr_to_stdout` because onboarding reads the exit status and reports it,
  # and an adapter that lets stderr through instead prints somebody else's
  # diagnostics into the caller's output. `git config` in a directory that is
  # not a repository is the ordinary case — a generated app before its first
  # commit — and it says `fatal: not in a git directory` on the way to the
  # non-zero this already handles. `FileIO` has always passed it; a host adapter
  # would have had to know to.
  @spec cmd(t(), String.t(), String.t(), [String.t()]) :: {String.t(), non_neg_integer()}
  def cmd(io, root, command, args),
    do: call(io, root, :cmd, [command, args, [stderr_to_stdout: true]])

  @doc """
  The module an adapter dispatches to.

  Exposed so a host can assert the adapter it passed is the one being called —
  the check whose absence let this port go unused for a week while its own
  documentation said otherwise.
  """
  @spec module(t()) :: module()
  def module({module, _state}), do: module
  def module(module) when is_atom(module), do: module

  defp call({module, state}, _root, fun, args), do: apply(module, fun, [state | args])
  defp call(module, root, fun, args), do: apply(module, fun, [root | args])
end
