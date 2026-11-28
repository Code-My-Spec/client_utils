defmodule ClientUtils.Evidence.CTRFFormatterTest do
  @moduledoc """
  exunit-ctrf-formatter: `ClientUtils.Evidence.CTRFFormatter`, run beside the
  SARIF formatter under the evidence writer, writes one CTRF report
  per run to `.code_my_spec/evidence/<id>.ctrf.json`, valid against the CTRF
  schema vendored at `test/support/ctrf.schema.json`.

  The case runs the writer and both formatters against a throwaway Mix project in a
  throwaway git repository.
  """
  use ExUnit.Case, async: true

  @schema Path.expand("test/support/ctrf.schema.json")

  @mix_exs """
  defmodule Throwaway.MixProject do
    use Mix.Project
    def project, do: [app: :throwaway, version: "0.1.0", deps: []]
  end
  """

  # One passing test, one failing (its `test` line is 8), one skipped.
  @math_test """
  defmodule MathTest do
    use ExUnit.Case

    test "adds numbers" do
      Application.put_env(:client_utils, :ctrf_extra, %{"math.driver" => "abacus"}); assert 1 + 1 == 2
    end

    test "adds wrong" do
      assert 1 + 1 == 3
    end

    @tag :skip
    test "is skipped" do
      flunk("skipped")
    end
  end
  """

  setup do
    root = Path.join(System.tmp_dir!(), "ctrf_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "test"))
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(Path.join(root, ".gitignore"), "/.code_my_spec/evidence/\n_build/\n")
    File.write!(Path.join(root, "mix.exs"), @mix_exs)
    File.write!(Path.join(root, "test/test_helper.exs"), "ExUnit.start()\n")
    File.write!(Path.join(root, "test/math_test.exs"), @math_test)

    git!(root, ["init", "-q", "-b", "main"])
    git!(root, ["config", "user.name", "Tess Tester"])
    git!(root, ["config", "user.email", "tess@example.com"])
    git!(root, ["config", "commit.gpgsign", "false"])
    git!(root, ["add", "-A"])
    git!(root, ["commit", "-q", "-m", "first"])

    %{repo: root}
  end

  defp git!(repo, args) do
    {out, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    String.trim(out)
  end

  @tag timeout: 180_000
  test "exunit-ctrf-formatter: mix test writes a CTRF report that validates and counts right",
       ctx do
    args = [ClientUtils.EvidenceCase.script(), "run", "exunit", "--", "elixir"]

    env = [
      {"MIX_ENV", "test"},
      {"EVIDENCE_CONTEXT", nil},
      {"EVIDENCE_CORRELATION", nil}
      | Enum.map(
          ~w(MIX_EXS MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_LOCKFILE MIX_TEST_PARTITION),
          &{&1, nil}
        )
    ]

    {out, status} =
      System.cmd("elixir", args ++ ClientUtils.EvidenceCase.exunit(),
        cd: ctx.repo,
        env: env,
        stderr_to_stdout: true
      )

    # The verdict and the SARIF evidence stay as they were.
    assert status == 2, out
    assert out =~ "1) test adds wrong (MathTest)"
    evidence = Path.join(ctx.repo, ".code_my_spec/evidence")
    assert [sarif] = Path.wildcard(Path.join(evidence, "*.sarif"))
    [run] = sarif |> File.read!() |> Jason.decode!() |> Map.fetch!("runs")

    assert run["results"] |> Enum.map(&{&1["kind"], &1["ruleId"]}) |> Enum.sort() == [
             {"fail", "MathTest test adds wrong"},
             {"pass", "MathTest test adds numbers"}
           ]

    # One CTRF report for the run, valid against the vendored schema.
    assert [path] = Path.wildcard(Path.join(evidence, "*.ctrf.json")), out
    report = path |> File.read!() |> Jason.decode!()
    root = @schema |> File.read!() |> Jason.decode!() |> JSV.build!(formats: true)

    assert {:ok, _} = JSV.validate(report, root),
           inspect(JSV.validate(report, root), pretty: true)

    assert Path.basename(path, ".ctrf.json") == report["reportId"]
    results = report["results"]
    assert results["tool"]["name"] == "ExUnit"

    assert %{
             "tests" => 3,
             "passed" => 1,
             "failed" => 1,
             "skipped" => 1,
             "pending" => 0,
             "other" => 0,
             "start" => start,
             "stop" => stop
           } = results["summary"]

    assert report["specVersion"] == "0.3.0"

    # Integer milliseconds everywhere: start, stop and every duration.
    assert is_integer(start) and is_integer(stop) and start <= stop
    assert results["summary"]["duration"] == stop - start
    assert Enum.all?(results["tests"], &is_integer(&1["duration"]))

    tests = Map.new(results["tests"], &{&1["name"], &1})

    assert Map.new(tests, fn {name, test} -> {name, test["status"]} end) == %{
             "MathTest test adds numbers" => "passed",
             "MathTest test adds wrong" => "failed",
             "MathTest test is skipped" => "skipped"
           }

    failed = tests["MathTest test adds wrong"]
    assert %{"filePath" => "test/math_test.exs", "line" => 8, "suite" => ["MathTest"]} = failed
    assert failed["message"] =~ "Assertion with == failed"
    assert failed["trace"] =~ "test/math_test.exs:9"
    assert tests["MathTest test is skipped"]["tags"] == ["skip"]
    refute Map.has_key?(tests["MathTest test adds numbers"], "message")

    head = git!(ctx.repo, ["rev-parse", "HEAD"])
    tree = git!(ctx.repo, ["rev-parse", "HEAD^{tree}"])

    assert results["environment"] == %{
             "commit" => head,
             "branchName" => "main",
             "extra" => %{"codemyspec.tree" => tree, "math.driver" => "abacus"}
           }
  end
end
