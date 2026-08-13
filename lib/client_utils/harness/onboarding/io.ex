defmodule ClientUtils.Harness.Onboarding.IO do
  @moduledoc """
  How onboarding reaches a working copy.

  Four operations, all rooted at the copy's directory, so the code that decides
  what a working copy needs never learns how the host stores it.
  `ClientUtils.Harness.Onboarding.FileIO` is the default and is what a generated
  application uses; CodeMySpec passes an adapter over its own `Environments` so
  the same onboarding runs against an in-memory copy in a spec.

  Paths are always relative to the root and always use forward slashes.
  """

  @doc "Contents of `path` under `root`, or an error when it is not there."
  @callback read(root :: String.t(), path :: String.t()) ::
              {:ok, String.t()} | {:error, term()}

  @doc "Write `contents` to `path` under `root`, creating parents."
  @callback write(root :: String.t(), path :: String.t(), contents :: String.t()) ::
              :ok | {:error, term()}

  @doc "Whether `path` exists under `root`."
  @callback exists?(root :: String.t(), path :: String.t()) :: boolean()

  @doc """
  Run `command` with `args` in `root`, returning `{output, exit_status}`.

  Never raises — a missing binary is `{message, non-zero}`. Onboarding treats a
  step that could not run the same as one that refused, and neither aborts the
  command.
  """
  @callback cmd(root :: String.t(), command :: String.t(), args :: [String.t()]) ::
              {String.t(), non_neg_integer()}
end
