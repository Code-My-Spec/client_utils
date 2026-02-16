defmodule ClientUtils.DiagnosticsFormat do
  @moduledoc """
  Serializes `Mix.Task.Compiler.Diagnostic` structs to JSON-compatible maps.
  """

  alias Mix.Task.Compiler.Diagnostic

  @doc """
  Encodes a list of diagnostics as JSONL (one JSON object per line).
  """
  @spec to_jsonl([Diagnostic.t()]) :: iodata()
  def to_jsonl(diagnostics) do
    diagnostics
    |> Enum.map(fn diag -> Jason.encode!(to_map(diag)) end)
    |> Enum.intersperse("\n")
  end

  @doc """
  Converts a diagnostic struct to a plain map suitable for JSON encoding.
  """
  @spec to_map(Diagnostic.t()) :: map()
  def to_map(%Diagnostic{} = diagnostic) do
    %{
      file: diagnostic.file,
      source: diagnostic.source,
      severity: diagnostic.severity,
      message: diagnostic.message,
      position: format_position(diagnostic.position),
      compiler_name: diagnostic.compiler_name,
      span: format_span(diagnostic.span),
      details: format_details(diagnostic.details),
      stacktrace: format_stacktrace(diagnostic.stacktrace)
    }
  end

  defp format_position(nil), do: nil
  defp format_position(line) when is_integer(line), do: line
  defp format_position({line, column}), do: %{line: line, column: column}

  defp format_span(nil), do: nil
  defp format_span({line, column}), do: %{line: line, column: column}

  defp format_stacktrace(nil), do: nil
  defp format_stacktrace([]), do: []

  defp format_stacktrace(stacktrace) when is_list(stacktrace) do
    Enum.map(stacktrace, fn
      {module, function, arity, location} when is_atom(module) ->
        %{
          module: module,
          function: function,
          arity: format_arity(arity),
          file: Keyword.get(location, :file),
          line: Keyword.get(location, :line),
          column: Keyword.get(location, :column)
        }

      {fun, arity, location} when is_function(fun) ->
        %{
          function: "(anonymous)",
          arity: format_arity(arity),
          file: Keyword.get(location, :file),
          line: Keyword.get(location, :line),
          column: Keyword.get(location, :column)
        }

      other ->
        inspect(other)
    end)
  end

  defp format_details(nil), do: nil
  defp format_details(d) when is_binary(d) or is_number(d) or is_atom(d), do: d
  defp format_details(d) when is_map(d) or is_list(d) do
    case Jason.encode(d) do
      {:ok, _} -> d
      {:error, _} -> inspect(d)
    end
  end
  defp format_details(d), do: inspect(d)

  defp format_arity(arity) when is_integer(arity), do: arity
  defp format_arity(args) when is_list(args), do: length(args)
end
