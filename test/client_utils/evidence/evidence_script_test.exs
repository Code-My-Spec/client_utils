defmodule ClientUtils.Evidence.EvidenceScriptTest do
  @moduledoc """
  evidence-writer-in-the-plugin: `priv/evidence.exs` runs an analyzer and
  writes one standard SARIF 2.1.0 file for that invocation.

  evidence-writer-records-every-test: the file goes to `.code_my_spec/evidence/`
  in the project directory as `<guid>.sarif`; a `mix test` run with
  `ClientUtils.Evidence.Formatter` records every test that ran, pass or fail.

  Each case runs the script with `elixir` against a throwaway git repository in
  a temporary directory.
  """
  use ExUnit.Case, async: true

  @script ClientUtils.EvidenceCase.script()
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  @failing_mix_test """
  #!/bin/sh
  cat <<'EOF'
  Running ExUnit with seed: 1, max_cases: 20

    1) test adds numbers (MathTest)
       test/math_test.exs:12
       Assertion with == failed
       code:  assert 1 + 1 == 3

    2) test subtracts (MathTest)
       test/math_test.exs:20
       ** (RuntimeError) boom

  Finished in 0.1 seconds (0.1s async, 0.00s sync)
  2 tests, 2 failures
  EOF
  exit 2
  """

  @credo_sarif ~s({"version":"2.1.0","runs":[{"tool":{"driver":{"name":"credo","version":"1.7.19"}},) <>
                 ~s("results":[{"ruleId":"EX4001","level":"warning","message":{"text":"Pipe chain"},) <>
                 ~s("locations":[{"physicalLocation":{"artifactLocation":{"uri":"lib/a.ex"},"region":{"startLine":3}}}]}]}]})

  # A throwaway Mix project: one passing test, one failing, one skipped, one
  # excluded. The failing test's `test` line is 8.
  @mix_exs """
  defmodule Throwaway.MixProject do
    use Mix.Project
    def project, do: [app: :throwaway, version: "0.1.0", deps: []]
  end
  """

  @math_test """
  defmodule MathTest do
    use ExUnit.Case

    test "adds numbers" do
      assert 1 + 1 == 2
    end

    test "adds wrong" do
      assert 1 + 1 == 3
    end

    @tag :skip
    test "is skipped" do
      flunk("skipped")
    end

    @tag :slow
    test "is excluded" do
      flunk("excluded")
    end
  end
  """

  setup do
    root = Path.join(System.tmp_dir!(), "evidence_#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    bin = Path.join(root, "bin")
    File.mkdir_p!(repo)
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf!(root) end)

    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.name", "Tess Tester"])
    git!(repo, ["config", "user.email", "tess@example.com"])
    git!(repo, ["config", "commit.gpgsign", "false"])
    git!(repo, ["remote", "add", "origin", "https://tess:s3cret@example.com/acme/widgets.git"])
    File.write!(Path.join(repo, ".gitignore"), "ignored.txt\n/.code_my_spec/evidence/\n")
    File.write!(Path.join(repo, "a.txt"), "one\n")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "first"])

    %{root: root, repo: repo, bin: bin, out: Path.join(repo, ".code_my_spec/evidence")}
  end

  defp git!(repo, args) do
    {out, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    String.trim(out)
  end

  defp tool!(ctx, name, body) do
    path = Path.join(ctx.bin, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end

  defp evidence(ctx, args, env \\ %{}) do
    System.cmd("elixir", [@script | args],
      cd: ctx.repo,
      env: env(ctx, env),
      stderr_to_stdout: true
    )
  end

  defp env(ctx, env) do
    %{
      "EVIDENCE_CONTEXT" => nil,
      "EVIDENCE_CORRELATION" => nil,
      "PATH" => ctx.bin <> ":" <> System.get_env("PATH")
    }
    |> Map.merge(env)
    |> Enum.to_list()
  end

  defp sarifs(dir) do
    dir
    |> Path.join("*.sarif")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      {Path.basename(path, ".sarif"), path |> File.read!() |> Jason.decode!()}
    end)
  end

  defp only_run(dir) do
    assert [{guid, %{"version" => "2.1.0", "runs" => [run]}}] = sarifs(dir)
    {guid, run}
  end

  test "evidence-writer-in-the-plugin: criterion 1 a passing command writes <guid>.sarif with every field",
       ctx do
    assert {out, 0} = evidence(ctx, ["run", "exunit", "--", "echo", "all good"])
    assert out =~ "all good"

    {guid, run} = only_run(ctx.out)
    assert guid =~ @uuid
    assert File.ls!(ctx.out) == [guid <> ".sarif"], "only the SARIF file, no meta.json"

    assert run["tool"]["driver"]["name"] == "exunit"
    assert run["tool"]["driver"]["version"] == System.version()

    assert [invocation] = run["invocations"]
    assert invocation["commandLine"] == "echo 'all good'"
    assert invocation["arguments"] == ["all good"]
    assert invocation["exitCode"] == 0
    assert invocation["executionSuccessful"] == true
    {:ok, started, _} = DateTime.from_iso8601(invocation["startTimeUtc"])
    {:ok, ended, _} = DateTime.from_iso8601(invocation["endTimeUtc"])
    assert DateTime.compare(started, ended) in [:lt, :eq]
    assert invocation["workingDirectory"]["uri"] =~ ~r{\Afile:///.*/repo/?\z}

    assert [provenance] = run["versionControlProvenance"]
    assert provenance["repositoryUri"] == "https://example.com/acme/widgets.git"
    assert provenance["revisionId"] == git!(ctx.repo, ["rev-parse", "HEAD"])
    assert provenance["branch"] == "main"
    assert provenance["properties"]["tree"] == git!(ctx.repo, ["rev-parse", "HEAD^{tree}"])

    assert run["automationDetails"]["id"] == "manual/Tess Tester"
    assert run["automationDetails"]["guid"] == guid
    assert run["automationDetails"]["correlationGuid"] =~ @uuid
    refute run["automationDetails"]["correlationGuid"] == guid

    assert run["results"] == []
  end

  test "evidence-writer-in-the-plugin: criterion 1 the script exits with the command's status",
       ctx do
    assert {_, 3} = evidence(ctx, ["run", "x", "--", "sh", "-c", "exit 3"])
    {_, run} = only_run(ctx.out)
    assert [%{"exitCode" => 3, "executionSuccessful" => false}] = run["invocations"]
  end

  test "evidence-writer-in-the-plugin: criterion 2 any other failure is one error with the output's last 4000 characters",
       ctx do
    command = "head -c 5000 /dev/zero | tr '\\0' x; echo END; exit 1"
    assert {_, 1} = evidence(ctx, ["run", "compiler", "--", "sh", "-c", command])

    {_, run} = only_run(ctx.out)
    assert [%{"level" => "error", "message" => %{"text" => text}} = result] = run["results"]
    assert String.length(text) == 4000
    assert String.ends_with?(text, "xEND\n")
    refute Map.has_key?(result, "locations")
  end

  test "evidence-writer-in-the-plugin: criterion 3 a dirty tree's hash covers what was tested and leaves the index alone",
       ctx do
    File.write!(Path.join(ctx.repo, "b.txt"), "staged\n")
    git!(ctx.repo, ["add", "b.txt"])
    File.write!(Path.join(ctx.repo, "a.txt"), "changed, not staged\n")
    File.write!(Path.join(ctx.repo, "c.txt"), "untracked\n")
    File.write!(Path.join(ctx.repo, "ignored.txt"), "ignored\n")

    cached = git!(ctx.repo, ["diff", "--cached"])
    status = git!(ctx.repo, ["status", "--porcelain"])
    assert cached =~ "b.txt"

    assert {_, 0} = evidence(ctx, ["run", "exunit", "--", "true"])

    assert git!(ctx.repo, ["diff", "--cached"]) == cached
    assert git!(ctx.repo, ["status", "--porcelain"]) == status

    {_, run} = only_run(ctx.out)
    [%{"properties" => %{"tree" => tree}}] = run["versionControlProvenance"]
    refute tree == git!(ctx.repo, ["rev-parse", "HEAD^{tree}"])

    assert git!(ctx.repo, ["cat-file", "-t", tree]) == "tree"
    files = ctx.repo |> git!(["ls-tree", "--name-only", tree]) |> String.split("\n")
    assert Enum.sort(files) == [".gitignore", "a.txt", "b.txt", "c.txt"]
    assert git!(ctx.repo, ["show", "#{tree}:a.txt"]) == "changed, not staged"
  end

  test "evidence-writer-in-the-plugin: criterion 4 context and correlation come from the environment, guid is new each time",
       ctx do
    env = %{
      "EVIDENCE_CONTEXT" => "ci/job-7",
      "EVIDENCE_CORRELATION" => "5b1c6f0e-0000-4000-8000-000000000001"
    }

    assert {_, 0} = evidence(ctx, ["run", "exunit", "--", "true"], env)
    assert {_, 1} = evidence(ctx, ["run", "exunit", "--", "false"], env)

    assert [{g1, %{"runs" => [r1]}}, {g2, %{"runs" => [r2]}}] = sarifs(ctx.out)
    refute g1 == g2

    for {guid, run} <- [{g1, r1}, {g2, r2}] do
      assert run["automationDetails"] == %{
               "id" => "ci/job-7",
               "guid" => guid,
               "correlationGuid" => "5b1c6f0e-0000-4000-8000-000000000001"
             }
    end

    File.rm_rf!(ctx.out)
    assert {_, 0} = evidence(ctx, ["run", "exunit", "--", "true"])
    assert {_, 0} = evidence(ctx, ["run", "exunit", "--", "true"])
    assert [{_, %{"runs" => [a]}}, {_, %{"runs" => [b]}}] = sarifs(ctx.out)
    refute a["automationDetails"]["correlationGuid"] == b["automationDetails"]["correlationGuid"]
  end

  test "evidence-writer-in-the-plugin: criterion 4 the default context falls back to $USER without a git user.name",
       ctx do
    git!(ctx.repo, ["config", "--unset", "user.name"])

    env = %{
      "USER" => "fallback-user",
      "GIT_CONFIG_GLOBAL" => "/nonexistent",
      "GIT_CONFIG_NOSYSTEM" => "1"
    }

    assert {_, 0} = evidence(ctx, ["run", "exunit", "--", "true"], env)

    {_, run} = only_run(ctx.out)
    assert run["automationDetails"]["id"] == "manual/fallback-user"
  end

  test "evidence-writer-in-the-plugin: criterion 5 stamp keeps the tool's own SARIF and adds the rest",
       ctx do
    tool!(ctx, "fake-credo", "#!/bin/sh\nprintf '%s' '#{@credo_sarif}'\nexit 4\n")
    raw = Path.join(ctx.root, "credo_stdout.sarif")

    assert {_, 4} =
             evidence(ctx, [
               "stamp",
               "credo",
               raw,
               "--",
               "fake-credo",
               "--format",
               "sarif"
             ])

    assert File.read!(raw) == @credo_sarif

    {guid, run} = only_run(ctx.out)
    %{"runs" => [tool_run]} = Jason.decode!(@credo_sarif)

    assert run["tool"] == tool_run["tool"]
    assert run["results"] == tool_run["results"]

    assert [invocation] = run["invocations"]
    assert invocation["commandLine"] == "fake-credo --format sarif"
    assert invocation["arguments"] == ["--format", "sarif"]
    assert invocation["exitCode"] == 4
    assert invocation["executionSuccessful"] == false
    assert invocation["startTimeUtc"] && invocation["endTimeUtc"]
    assert invocation["workingDirectory"]["uri"] =~ "file://"

    assert [
             %{"repositoryUri" => "https://example.com/acme/widgets.git", "branch" => "main"} =
               provenance
           ] =
             run["versionControlProvenance"]

    assert provenance["revisionId"] == git!(ctx.repo, ["rev-parse", "HEAD"])
    assert provenance["properties"]["tree"] == git!(ctx.repo, ["rev-parse", "HEAD^{tree}"])

    assert %{"id" => "manual/Tess Tester", "guid" => ^guid, "correlationGuid" => _} =
             run["automationDetails"]
  end

  # credo's SARIF as a BEAM with no locale printed it: the em dash came out as
  # Erlang's `\x{2014}`, which is no JSON escape.
  @credo_sarif_escaped ~S({"version":"2.1.0","runs":[{"tool":{"driver":{"name":"credo"}},) <>
                         ~S("results":[{"ruleId":"EX1001","level":"error",) <>
                         ~S("message":{"text":"Avoid this \x{2014} it blocks"},) <>
                         ~S("locations":[{"physicalLocation":{"artifactLocation":{"uri":"lib/a.ex"},"region":{"startLine":7}}}]}]}]})

  defp stamp_credo(ctx, stdout, status) do
    fixture = Path.join(ctx.root, "credo_fixture.out")
    File.write!(fixture, stdout)
    tool!(ctx, "fake-credo", "#!/bin/sh\ncat '#{fixture}'\nexit #{status}\n")
    raw = Path.join(ctx.root, "credo_stdout.sarif")
    {_, code} = evidence(ctx, ["stamp", "credo", raw, "--", "fake-credo"])
    {code, raw}
  end

  test "credo-output-hides-blockers: criterion 2 credo SARIF with a non-ASCII message parses and keeps its blocking finding",
       ctx do
    assert {1, _raw} = stamp_credo(ctx, @credo_sarif_escaped, 1)
    {_, run} = only_run(ctx.out)

    assert run["tool"]["driver"]["name"] == "credo"

    assert [
             %{
               "ruleId" => "EX1001",
               "level" => "error",
               "message" => %{"text" => "Avoid this — it blocks"},
               "locations" => [_]
             }
           ] = run["results"]
  end

  test "credo-output-hides-blockers: criterion 1 a non-zero exit with unparseable output is a parse error, output kept whole",
       ctx do
    garbage = String.duplicate("x", 200_000) <> " {not sarif\n"
    assert {1, raw} = stamp_credo(ctx, garbage, 1)
    assert File.read!(raw) == garbage

    {_, run} = only_run(ctx.out)
    assert [%{"level" => "error", "message" => %{"text" => text}}] = run["results"]
    assert text =~ "exited 1 and printed no SARIF that parses"
    assert text =~ "invalid_byte"
    assert text =~ "the complete output is #{raw}"
  end

  test "credo-output-hides-blockers: criterion 1 a non-zero exit whose SARIF names no blocking finding is not clean",
       ctx do
    empty = ~S({"version":"2.1.0","runs":[{"tool":{"driver":{"name":"credo"}},"results":[]}]})
    assert {1, raw} = stamp_credo(ctx, empty, 1)

    {_, run} = only_run(ctx.out)
    assert [%{"level" => "error", "message" => %{"text" => text}}] = run["results"]
    assert text =~ "exited 1 but its SARIF names no error or warning finding"
    assert text =~ raw
  end

  test "evidence-writer-in-the-plugin: criterion 5 run --attach copies the screenshots beside the SARIF",
       ctx do
    shots = Path.join(ctx.root, "shots")
    File.mkdir_p!(Path.join(shots, "journey-1"))
    File.write!(Path.join(shots, "first.png"), "png 1")
    File.write!(Path.join([shots, "journey-1", "second.png"]), "png 2")
    File.write!(Path.join([shots, "journey-1", "slides.html"]), "<html>")

    assert {_, 0} = evidence(ctx, ["run", "exunit", "--attach", shots, "--", "true"])
    {guid, run} = only_run(ctx.out)

    assert run["results"] == []
    uris = Enum.map(run["properties"]["attachments"], & &1["artifactLocation"]["uri"])
    assert uris == ["#{guid}/first.png", "#{guid}/journey-1/second.png"]

    for uri <- uris do
      assert File.exists?(Path.join(ctx.out, uri)), "#{uri} is not relative to the SARIF file"
    end

    refute File.exists?(Path.join([ctx.out, guid, "journey-1", "slides.html"]))

    File.rm_rf!(ctx.out)
    assert {_, 1} = evidence(ctx, ["run", "exunit", "--attach", shots, "--", "false"])
    {guid, run} = only_run(ctx.out)
    assert [result] = run["results"]

    assert Enum.map(result["attachments"], & &1["artifactLocation"]["uri"]) ==
             ["#{guid}/first.png", "#{guid}/journey-1/second.png"]

    assert File.read!(Path.join([ctx.out, guid, "journey-1", "second.png"])) == "png 2"
  end

  @tag timeout: 180_000
  test "evidence-writer-records-every-test: criterion 1 a mix test run with the formatter records every test that ran, pass and fail",
       ctx do
    File.write!(
      Path.join(ctx.repo, ".gitignore"),
      "ignored.txt\n/.code_my_spec/evidence/\n_build/\n"
    )

    File.write!(Path.join(ctx.repo, "mix.exs"), @mix_exs)
    File.mkdir_p!(Path.join(ctx.repo, "test"))
    File.write!(Path.join(ctx.repo, "test/test_helper.exs"), "ExUnit.start(exclude: [:slow])\n")
    File.write!(Path.join(ctx.repo, "test/math_test.exs"), @math_test)

    args = ["run", "exunit", "--", "elixir" | ClientUtils.EvidenceCase.exunit()]

    env =
      env(ctx, %{
        "MIX_ENV" => "test",
        "MIX_EXS" => nil,
        "MIX_BUILD_PATH" => nil,
        "MIX_BUILD_ROOT" => nil,
        "MIX_DEPS_PATH" => nil,
        "MIX_LOCKFILE" => nil,
        "MIX_TEST_PARTITION" => nil
      })

    mix_test = fn ->
      System.cmd("elixir", [@script | args], cd: ctx.repo, env: env, stderr_to_stdout: true)
    end

    {out, status} = mix_test.()
    assert status == 2, out

    # The default CLI formatter still prints.
    assert out =~ "1) test adds wrong (MathTest)"
    assert out =~ "test/math_test.exs:8"
    assert out =~ "Finished in "
    assert out =~ "1 skipped"
    assert out =~ "1 excluded"

    {_guid, run} = only_run(ctx.out)
    assert run["tool"]["driver"] == %{"name" => "exunit", "version" => System.version()}
    assert [%{"exitCode" => 2, "commandLine" => command_line}] = run["invocations"]

    assert command_line =~
             "--formatter ClientUtils.Evidence.Formatter --formatter ExUnit.CLIFormatter"

    assert [%{"properties" => %{"tree" => _}}] = run["versionControlProvenance"]
    assert %{"id" => _, "guid" => _, "correlationGuid" => _} = run["automationDetails"]

    # Two results, in the order the seed ran them: the skipped and the
    # excluded tests are not results.
    assert [fail, pass] = Enum.sort_by(run["results"], & &1["kind"])

    assert pass == %{
             "kind" => "pass",
             "level" => "none",
             "ruleId" => "MathTest test adds numbers"
           }

    assert fail["kind"] == "fail"
    assert fail["level"] == "error"
    assert fail["ruleId"] == "MathTest test adds wrong"
    assert fail["message"]["text"] =~ "test adds wrong (MathTest)"
    assert fail["message"]["text"] =~ "Assertion with == failed"

    assert [
             %{
               "physicalLocation" => %{
                 "artifactLocation" => %{"uri" => "test/math_test.exs"},
                 "region" => %{"startLine" => 8}
               }
             }
           ] = fail["locations"]

    # A green run still records its passing tests.
    File.write!(
      Path.join(ctx.repo, "test/math_test.exs"),
      String.replace(@math_test, "1 + 1 == 3", "1 + 2 == 3")
    )

    File.rm_rf!(ctx.out)
    {out, status} = mix_test.()
    assert status == 0, out
    {_guid, run} = only_run(ctx.out)

    assert run["results"] |> Enum.map(&{&1["kind"], &1["ruleId"]}) |> Enum.sort() == [
             {"pass", "MathTest test adds numbers"},
             {"pass", "MathTest test adds wrong"}
           ]
  end

  test "evidence-writer-records-every-test: criterion 2 run mode no longer parses mix test output",
       ctx do
    tool!(ctx, "mix", @failing_mix_test)

    assert {_, 2} = evidence(ctx, ["run", "exunit", "--", "mix", "test"])
    {_, run} = only_run(ctx.out)

    # Without the formatter, a red mix test is one error with the output's tail,
    # as for any other command: no results read out of the console text.
    assert [%{"level" => "error", "message" => %{"text" => text}} = result] = run["results"]
    assert text =~ "1) test adds numbers (MathTest)"
    assert text =~ "2 tests, 2 failures"
    refute Map.has_key?(result, "locations")
    refute Map.has_key?(result, "kind")
  end

  test "evidence-writer-records-every-test: criterion 3 evidence goes to .code_my_spec/evidence/, which git ignores",
       ctx do
    assert {_, 0} = evidence(ctx, ["run", "format", "--", "true"])
    assert File.ls!(ctx.repo) |> Enum.sort() == [".code_my_spec", ".git", ".gitignore", "a.txt"]
    assert File.ls!(Path.join(ctx.repo, ".code_my_spec")) == ["evidence"]
    assert [{guid, _}] = sarifs(ctx.out)
    assert guid =~ @uuid

    for path <- [
          ".code_my_spec/evidence/#{guid}.sarif",
          ".code_my_spec/evidence/#{guid}/shot.png"
        ] do
      assert {_, 0} = System.cmd("git", ["check-ignore", "-q", path]),
             "#{path} is not ignored by this repository's .gitignore"
    end
  end
end
