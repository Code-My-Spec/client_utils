defmodule ClientUtils.EvidenceCase do
  @moduledoc false

  @doc "The elixir arguments for `mix test` with both evidence formatters, in a project without client_utils."
  def exunit do
    [
      "-r",
      Path.expand("lib/client_utils/evidence/formatter.ex"),
      "-r",
      Path.expand("lib/client_utils/evidence/ctrf_formatter.ex"),
      "-S",
      "mix",
      "test",
      "--formatter",
      "ClientUtils.Evidence.Formatter",
      "--formatter",
      "ExUnit.CLIFormatter",
      "--formatter",
      "ClientUtils.Evidence.CTRFFormatter"
    ]
  end

  @doc "The evidence writer."
  def script, do: Path.expand("priv/evidence.exs")
end
