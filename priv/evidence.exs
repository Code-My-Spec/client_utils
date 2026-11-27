# Evidence writer: one standard SARIF 2.1.0 file per analyzer invocation.
#
#   elixir deps/client_utils/priv/evidence.exs run <analyzer> [--attach <folder>] -- <command> [args...]
#   elixir deps/client_utils/priv/evidence.exs stamp <analyzer> <sarif file> -- <command> [args...]
#
# Every file goes to `.code_my_spec/evidence/` in the project directory (the
# working directory), as `<guid>.sarif`; the path encodes nothing, the file
# carries its tree and commit.
#
# `run` runs the command with EVIDENCE_EXUNIT_SARIF set to a temporary path. A
# test run with ClientUtils.Evidence.Formatter
# writes a SARIF there with a result per test, pass or fail, and those are the
# results. Otherwise: none on exit 0, else one error holding the output's last
# 4000 characters; a red run whose results hold no failure gets that error too.
# `--attach <folder>` copies the folder's .png files (subfolders included) into
# `<guid>/` beside the SARIF and lists them as attachments, with uris relative
# to the SARIF file: on the first result, or in the run's properties when there
# is none.
#
# `stamp` is for a tool that prints its own SARIF on stdout (credo --format
# sarif): its stdout is saved to <sarif file> and its driver and results are
# kept as they are.
#
# Both fill in runs[0].invocations[0], versionControlProvenance[0] and
# automationDetails, write `<guid>.sarif`, and exit with the command's
# status. Everything is SARIF's own fields; nothing else is written.
#
#   automationDetails.id               EVIDENCE_CONTEXT, default "manual/<git user.name or $USER>"
#   automationDetails.correlationGuid  EVIDENCE_CORRELATION, default a new uuid
#   versionControlProvenance[0].properties.tree
#       the tree actually tested: HEAD plus every uncommitted and untracked (not
#       ignored) file, written through a temporary index so the real one is
#       never touched. On a clean tree it equals HEAD^{tree}.
#
# Plain `elixir`, no mix project: JSON through OTP's :json when it has one, else
# the small codec below.

defmodule Evidence.Json do
  @moduledoc false

  def encode(term) do
    if otp_json?(:encode),
      do: IO.iodata_to_binary(:json.encode(nulls(term))),
      else: IO.iodata_to_binary(enc(term))
  end

  def decode(binary) do
    if otp_json?(:decode) do
      {:ok, binary |> :json.decode() |> nils()}
    else
      {value, rest} = val(skip(binary))
      if skip(rest) == "", do: {:ok, value}, else: {:error, "text after the JSON value"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp otp_json?(fun), do: Code.ensure_loaded?(:json) and function_exported?(:json, fun, 1)

  defp nulls(nil), do: :null
  defp nulls(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, nulls(v)} end)
  defp nulls(list) when is_list(list), do: Enum.map(list, &nulls/1)
  defp nulls(other), do: other

  defp nils(:null), do: nil
  defp nils(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, nils(v)} end)
  defp nils(list) when is_list(list), do: Enum.map(list, &nils/1)
  defp nils(other), do: other

  defp enc(nil), do: "null"
  defp enc(true), do: "true"
  defp enc(false), do: "false"
  defp enc(n) when is_integer(n), do: Integer.to_string(n)
  defp enc(f) when is_float(f), do: Float.to_string(f)
  defp enc(a) when is_atom(a), do: enc(Atom.to_string(a))
  defp enc(s) when is_binary(s), do: [?", esc(s), ?"]
  defp enc(l) when is_list(l), do: [?[, Enum.map_intersperse(l, ?,, &enc/1), ?]]

  defp enc(m) when is_map(m),
    do: [?{, Enum.map_intersperse(m, ?,, fn {k, v} -> [enc(to_string(k)), ?:, enc(v)] end), ?}]

  defp esc(s) do
    for <<c::utf8 <- s>>, into: "" do
      case c do
        ?" -> "\\\""
        ?\\ -> "\\\\"
        ?\n -> "\\n"
        ?\r -> "\\r"
        ?\t -> "\\t"
        c when c < 0x20 -> "\\u" <> String.pad_leading(Integer.to_string(c, 16), 4, "0")
        c -> <<c::utf8>>
      end
    end
  end

  defp skip(<<c, rest::binary>>) when c in [?\s, ?\t, ?\r, ?\n], do: skip(rest)
  defp skip(rest), do: rest

  defp val("{" <> rest), do: obj(skip(rest), %{})
  defp val("[" <> rest), do: arr(skip(rest), [])
  defp val("\"" <> rest), do: str(rest, [])
  defp val("true" <> rest), do: {true, rest}
  defp val("false" <> rest), do: {false, rest}
  defp val("null" <> rest), do: {nil, rest}

  defp val(rest) do
    [num] = Regex.run(~r/\A-?\d+(\.\d+)?([eE][+-]?\d+)?/, rest, capture: :first)
    tail = binary_part(rest, byte_size(num), byte_size(rest) - byte_size(num))

    if String.contains?(num, [".", "e", "E"]),
      do: {elem(Float.parse(num), 0), tail},
      else: {String.to_integer(num), tail}
  end

  defp obj("}" <> rest, acc), do: {acc, rest}

  defp obj("\"" <> rest, acc) do
    {key, rest} = str(rest, [])
    ":" <> rest = skip(rest)
    {value, rest} = val(skip(rest))
    acc = Map.put(acc, key, value)

    case skip(rest) do
      "," <> rest -> obj(skip(rest), acc)
      "}" <> rest -> {acc, rest}
    end
  end

  defp arr("]" <> rest, acc), do: {Enum.reverse(acc), rest}

  defp arr(rest, acc) do
    {value, rest} = val(skip(rest))

    case skip(rest) do
      "," <> rest -> arr(skip(rest), [value | acc])
      "]" <> rest -> {Enum.reverse([value | acc]), rest}
    end
  end

  defp str("\"" <> rest, acc), do: {IO.iodata_to_binary(Enum.reverse(acc)), rest}

  defp str("\\u" <> <<hex::binary-4, rest::binary>>, acc),
    do: str(rest, [<<String.to_integer(hex, 16)::utf8>> | acc])

  defp str("\\" <> <<c, rest::binary>>, acc), do: str(rest, [unescape(c) | acc])
  defp str(<<c::utf8, rest::binary>>, acc), do: str(rest, [<<c::utf8>> | acc])

  defp unescape(?n), do: "\n"
  defp unescape(?t), do: "\t"
  defp unescape(?r), do: "\r"
  defp unescape(?b), do: "\b"
  defp unescape(?f), do: "\f"
  defp unescape(c), do: <<c>>
end

defmodule Evidence.Tee do
  @moduledoc false
  # Collects a command's output and, when echo is on, prints it as it comes.
  defstruct echo: true, acc: []
end

defimpl Collectable, for: Evidence.Tee do
  def into(tee) do
    {tee,
     fn
       t, {:cont, chunk} ->
         if t.echo, do: IO.binwrite(:stdio, chunk)
         %{t | acc: [t.acc | chunk]}

       t, :done ->
         IO.iodata_to_binary(t.acc)

       _, :halt ->
         :ok
     end}
  end
end

defmodule Evidence do
  @moduledoc false
  alias Evidence.Json

  @usage """
  usage: elixir evidence.exs run <analyzer> [--attach <folder>] -- <command> [args...]
         elixir evidence.exs stamp <analyzer> <sarif file> -- <command> [args...]
  """

  # Analyzers that run under the Elixir running this script.
  @elixir_analyzers ~w(exunit compiler format)

  # Where the evidence goes, in the project directory.
  @evidence ".code_my_spec/evidence"

  def main(["run", analyzer | rest]) do
    case run_opts(rest, nil) do
      {attach, [command | args]} -> run(analyzer, attach, command, args)
      _ -> usage()
    end
  end

  def main(["stamp", analyzer, file, "--", command | args]),
    do: stamp(analyzer, file, command, args)

  def main(_), do: usage()

  defp run_opts(["--attach", folder | rest], _), do: run_opts(rest, folder)
  defp run_opts(["--" | command], attach), do: {attach, command}
  defp run_opts(_, _), do: :error

  defp usage do
    IO.write(:stderr, @usage)
    System.halt(2)
  end

  defp run(analyzer, attach, command, args) do
    dir = Path.join(File.cwd!(), @evidence)
    guid = uuid()
    tests = Path.join(System.tmp_dir!(), "evidence-tests-#{guid}.sarif")
    started = now()

    {out, status} =
      exec(command, args,
        stderr_to_stdout: true,
        echo: true,
        env: [{"EVIDENCE_EXUNIT_SARIF", tests}]
      )

    ended = now()
    results = test_results(tests, out, status) || results(out, status)
    File.rm(tests)

    attachments = attach(attach, dir, guid)

    run =
      %{
        "tool" => %{"driver" => driver(analyzer)},
        "results" => results
      }
      |> with_attachments(attachments)
      |> stamp_run(guid, command, args, status, started, ended)

    write!(dir, guid, [run])
    System.halt(status)
  end

  defp stamp(analyzer, file, command, args) do
    dir = Path.join(File.cwd!(), @evidence)
    guid = uuid()
    started = now()
    {out, status} = exec(command, args, echo: false, env: utf8_locale())
    ended = now()

    # A tool that wrote the file itself instead of printing it keeps its file.
    out =
      if String.trim(out) == "" and File.regular?(file) do
        File.read!(file)
      else
        File.mkdir_p!(Path.dirname(file))
        File.write!(file, out)
        out
      end

    {run, others} =
      case tool_sarif(out) do
        {:ok, %{"runs" => [%{} = run | others]}} ->
          run = Map.update(run, "tool", %{"driver" => driver(analyzer)}, &named(&1, analyzer))
          {blocked(run, status, file), others}

        other ->
          reason =
            case other do
              {:error, reason} -> reason
              _ -> "JSON, but no runs[0]"
            end

          {%{
             "tool" => %{"driver" => driver(analyzer)},
             "results" => unparsed(out, status, reason, file)
           }, []}
      end

    write!(dir, guid, [stamp_run(run, guid, command, args, status, started, ended) | others])
    System.halt(status)
  end

  # Whatever a tool printed before its JSON (a compile line) is not SARIF.
  defp tool_sarif(out) do
    out = erlang_escapes(out)

    case Json.decode(out) do
      {:ok, %{} = sarif} ->
        {:ok, sarif}

      first ->
        case :binary.match(out, "{") do
          {at, _} -> Json.decode(binary_part(out, at, byte_size(out) - at))
          :nomatch -> first
        end
    end
  end

  # A BEAM with no UTF-8 locale prints a character past latin1 as `\x{2014}`,
  # inside JSON strings too, and that is no JSON escape. An escaped backslash
  # (`\\x{...}`) is left alone.
  defp erlang_escapes(out) do
    Regex.replace(~r/(?<!\\)((?:\\\\)*)\\x\{([0-9A-Fa-f]{1,6})\}/, out, fn whole, pre, hex ->
      case String.to_integer(hex, 16) do
        cp when cp <= 0x10FFFF and cp not in 0xD800..0xDFFF -> pre <> <<cp::utf8>>
        _ -> whole
      end
    end)
  end

  # The cause of those escapes: the child gets a UTF-8 locale when we have none.
  defp utf8_locale do
    if Enum.any?(~w(LC_ALL LC_CTYPE LANG), &env/1) do
      []
    else
      case :os.type() do
        {:unix, :darwin} -> [{"LC_CTYPE", "UTF-8"}]
        {:unix, _} -> [{"LC_CTYPE", "C.UTF-8"}]
        _ -> []
      end
    end
  end

  # A red tool whose SARIF names no error or warning (SARIF's default level)
  # is not a clean run: say so, and where its output is.
  defp blocked(run, 0, _file), do: run

  defp blocked(run, status, file) do
    results = List.wrap(run["results"])

    if Enum.any?(results, &((&1["level"] || "warning") in ~w(error warning))) do
      run
    else
      text =
        "exited #{status} but its SARIF names no error or warning finding; " <>
          "the complete output is #{Path.expand(file)}"

      Map.put(run, "results", results ++ [error(text)])
    end
  end

  # A red tool whose output is not SARIF: the parse error, where the whole
  # output is kept, and its tail.
  defp unparsed(_out, 0, _reason, _file), do: []

  defp unparsed(out, status, reason, file) do
    text =
      "exited #{status} and printed no SARIF that parses (#{reason}); " <>
        "the complete output is #{Path.expand(file)}\n" <> String.slice(out, -4000, 4000)

    [error(text)]
  end

  defp error(text), do: %{"level" => "error", "message" => %{"text" => text}}

  defp named(%{"driver" => %{"name" => _}} = tool, _analyzer), do: tool

  defp named(tool, analyzer),
    do: Map.update(tool, "driver", driver(analyzer), &Map.put(&1, "name", analyzer))

  defp driver(analyzer) when analyzer in @elixir_analyzers,
    do: %{"name" => analyzer, "version" => System.version()}

  defp driver(analyzer), do: %{"name" => analyzer}

  defp exec(command, args, opts) do
    {echo, opts} = Keyword.pop(opts, :echo)

    try do
      {out, status} = System.cmd(command, args, [into: %Evidence.Tee{echo: echo}] ++ opts)
      {String.replace_invalid(out), status}
    rescue
      e in ErlangError ->
        message = "#{command}: #{Exception.message(e)}\n"
        IO.write(:stderr, message)
        {message, 127}
    end
  end

  defp stamp_run(run, guid, command, args, status, started, ended) do
    Map.merge(run, %{
      "invocations" => [
        %{
          "commandLine" => Enum.map_join([command | args], " ", &shell_quote/1),
          "arguments" => args,
          "startTimeUtc" => started,
          "endTimeUtc" => ended,
          "exitCode" => status,
          "executionSuccessful" => status == 0,
          "workingDirectory" => %{"uri" => file_uri(File.cwd!())}
        }
      ],
      "versionControlProvenance" => [provenance()],
      "automationDetails" => %{
        "id" => context(),
        "guid" => guid,
        "correlationGuid" => env("EVIDENCE_CORRELATION") || uuid()
      }
    })
  end

  defp write!(dir, guid, runs) do
    sarif = %{
      "$schema" => "https://json.schemastore.org/sarif-2.1.0.json",
      "version" => "2.1.0",
      "runs" => runs
    }

    path = Path.join(dir, guid <> ".sarif")
    File.mkdir_p!(dir)
    File.write!(path, Json.encode(sarif))
    IO.puts(:stderr, "evidence: #{path}")
  end

  ## Results

  defp results(_out, 0), do: []
  defp results(out, _status), do: tail(out)

  defp tail(out),
    do: [%{"level" => "error", "message" => %{"text" => String.slice(out, -4000, 4000)}}]

  # The per-test results the ExUnit formatter left, if it ran. A red run with
  # no failing test among them (the suite passed, mix still failed) also gets
  # the output's tail, so the red is explained.
  defp test_results(path, out, status) do
    with {:ok, binary} <- File.read(path),
         {:ok, %{"runs" => [%{"results" => results} | _]}} when is_list(results) <-
           Json.decode(binary) do
      if status != 0 and not Enum.any?(results, &(&1["kind"] == "fail")),
        do: results ++ tail(out),
        else: results
    else
      _ -> nil
    end
  end

  ## Attachments

  defp attach(nil, _dir, _guid), do: []

  defp attach(folder, dir, guid) do
    folder = Path.expand(folder)

    for source <- folder |> Path.join("**/*.png") |> Path.wildcard() |> Enum.sort() do
      relative = Path.relative_to(source, folder)
      target = Path.join([dir, guid, relative])
      File.mkdir_p!(Path.dirname(target))
      File.cp!(source, target)

      %{
        "artifactLocation" => %{"uri" => URI.encode(Path.join(guid, relative))},
        "description" => %{"text" => relative}
      }
    end
  end

  defp with_attachments(run, []), do: run

  defp with_attachments(%{"results" => [first | rest]} = run, attachments),
    do: %{run | "results" => [Map.put(first, "attachments", attachments) | rest]}

  defp with_attachments(run, attachments),
    do: Map.put(run, "properties", %{"attachments" => attachments})

  ## Provenance

  defp provenance do
    head = git(["rev-parse", "HEAD"])

    %{
      "repositoryUri" => repository_uri(),
      "revisionId" => head,
      "branch" => git(["symbolic-ref", "--short", "-q", "HEAD"]),
      "properties" => %{"tree" => head && tested_tree()}
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp repository_uri do
    case git(["remote", "get-url", "origin"]) do
      nil ->
        if top = git(["rev-parse", "--show-toplevel"]), do: file_uri(top)

      url ->
        Regex.replace(~r{\A([a-z][a-z0-9+.-]*://)[^/@]*@}i, url, "\\1")
    end
  end

  # The working tree as tested, through a temporary index: the real one is
  # never read into or written.
  defp tested_tree do
    top = git(["rev-parse", "--show-toplevel"])
    index = Path.join(System.tmp_dir!(), "evidence-index-#{uuid()}")
    opts = [cd: top, env: [{"GIT_INDEX_FILE", index}], stderr_to_stdout: true]

    try do
      with {_, 0} <- System.cmd("git", ["read-tree", "HEAD"], opts),
           {_, 0} <- System.cmd("git", ["add", "-A"], opts),
           {tree, 0} <- System.cmd("git", ["write-tree"], opts) do
        String.trim(tree)
      else
        _ -> nil
      end
    after
      File.rm(index)
      File.rm(index <> ".lock")
    end
  end

  defp git(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> if (out = String.trim(out)) != "", do: out
      _ -> nil
    end
  rescue
    ErlangError -> nil
  end

  ## Automation

  defp context do
    env("EVIDENCE_CONTEXT") ||
      "manual/" <> (git(["config", "user.name"]) || env("USER") || "unknown")
  end

  defp env(name) do
    case System.get_env(name) do
      blank when blank in [nil, ""] -> nil
      value -> value
    end
  end

  ## Helpers

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  defp file_uri(path), do: "file://" <> URI.encode(String.trim_trailing(path, "/") <> "/")

  defp shell_quote(arg) do
    if arg =~ ~r{\A[\w@%+=:,./-]+\z},
      do: arg,
      else: "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end

  defp uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)

    <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> =
      Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)

    Enum.join([p1, p2, p3, p4, p5], "-")
  end
end

Evidence.main(System.argv())
