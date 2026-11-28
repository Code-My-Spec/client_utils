# The CI recipes: certify, ci, retry, journey-coverage. A project's justfile
# takes them with
#
#     set allow-duplicate-recipes
#     import? 'deps/client_utils/priv/ci.just'
#
# and replaces any of them by defining a recipe of the same name; `ci-extra`
# is the hook for a project's own ci checks. Run `mix deps.get` before `just ci`:
# these recipes exist only once the dep is fetched.
#
# Each analyzer call leaves one SARIF 2.1.0 file in .code_my_spec/evidence/
# through evidence.exs, and everything one recipe call runs shares one
# EVIDENCE_CORRELATION; a recipe called from another (certify from ci) keeps its
# caller's. The loop passes a folder to these recipes; it is accepted and unused.

# The evidence writer: a plain script, so it still records a project that does
# not compile.
evidence := "elixir " + quote(env("MIX_DEPS_PATH", justfile_directory() / "deps") / "client_utils/priv/evidence.exs")

# `mix test` with the evidence formatter (a result per test), the CLI formatter,
# and the CTRF formatter (.code_my_spec/evidence/<id>.ctrf.json).
exunit := "mix test --formatter ClientUtils.Evidence.Formatter --formatter ExUnit.CLIFormatter --formatter ClientUtils.Evidence.CTRFFormatter"

time_limit := quote(source_directory() / "time_limit.sh")

# Format, a warning-free compile and credo. Credo writes its own SARIF to
# stdout, which `stamp` keeps (complete stdout in .code_my_spec/evidence/credo.out),
# and exits non-zero on any finding.
#
# Format, compile and credo, each as SARIF evidence.
certify *_loop_dir:
    #!/usr/bin/env bash
    set -euo pipefail
    export EVIDENCE_CORRELATION="${EVIDENCE_CORRELATION:-$(uuidgen | tr 'A-Z' 'a-z')}"
    credo=".code_my_spec/evidence/credo.out"
    MIX_ENV=test {{evidence}} run format -- mix format --check-formatted
    MIX_ENV=test {{evidence}} run compiler -- mix compile --warnings-as-errors
    MIX_ENV=test {{evidence}} stamp credo "$credo" -- mix credo --strict --format sarif

# A project's own ci checks, run after certify.
ci-extra:
    @true

# certify, ci-extra, the suite on a fresh test database (a red suite re-runs once
# with --failed, in the same correlation), then the journeys on the LiveView
# driver under a 120 s limit (SIGTERM, then SIGKILL 10 s later), then journey
# coverage.
#
# The full ci: certify, ci-extra, the suite, the journeys, journey coverage.
ci *_loop_dir:
    #!/usr/bin/env bash
    set -euo pipefail
    export EVIDENCE_CORRELATION="${EVIDENCE_CORRELATION:-$(uuidgen | tr 'A-Z' 'a-z')}"
    just certify
    just ci-extra
    MIX_ENV=test mix ecto.create --quiet
    MIX_ENV=test mix ecto.migrate
    MIX_ENV=test {{evidence}} run exunit -- {{exunit}} ||
        MIX_ENV=test {{evidence}} run exunit -- {{exunit}} --failed
    MIX_ENV=test {{time_limit}} 120 10 "journey step" -- {{evidence}} run exunit -- {{exunit}} --seed 0 --include journey test/journeys/*_test.exs
    just journey-coverage

# Every stage of every .code_my_spec/journeys/*.yml passed in the last journeys
# run's CTRF report (skipped is not passed); red when one did not.
#
# Every journey stage passed in the last journeys run.
journey-coverage:
    MIX_ENV=test {{evidence}} stamp journey-coverage .code_my_spec/evidence/journey_coverage.out -- mix client_utils.journey_coverage

# After a red ci, re-run only what failed. The ci run it retries is the
# correlation of the exunit invocation in .code_my_spec/evidence that ended last.
# Per step (the suite; the journeys, whose arguments name test/journeys/), from
# its last invocation there: none (never reached, or killed) re-runs whole; exit
# 0 is skipped; red with failing tests re-runs --failed; any other red re-runs
# whole. The journeys always re-run whole: a stage starts from the one before.
# certify and ci-extra always run first (a red certify leaves no exunit evidence
# to retry from) and journey coverage always last. Non-zero if any still fails.
#
# Re-run only what the last ci left red.
retry *_loop_dirs:
    #!/usr/bin/env bash
    set -uo pipefail
    export EVIDENCE_CORRELATION="${EVIDENCE_CORRELATION:-$(uuidgen | tr 'A-Z' 'a-z')}"
    sarifs=(.code_my_spec/evidence/*.sarif)
    first="$(jq -s -r '[.[].runs[0] | select(.tool.driver.name == "exunit")]
        | sort_by(.invocations[0].endTimeUtc) | last | .automationDetails.correlationGuid // empty' "${sarifs[@]}" 2>/dev/null)"
    plan() {
        last="$(jq -s -c --arg first "$first" --argjson journeys "$1" '[.[].runs[0] | select(.tool.driver.name == "exunit")
            | select(.automationDetails.correlationGuid == $first)
            | select((.invocations[0].arguments | any(.[]; startswith("test/journeys/"))) == $journeys)]
            | sort_by(.invocations[0].endTimeUtc) | last // empty' "${sarifs[@]}" 2>/dev/null)"
        if [ -z "$last" ]; then echo whole
        elif [ "$(jq '.invocations[0].exitCode' <<<"$last")" = 0 ]; then echo skip
        elif jq -e '.results | any(.[]; .kind == "fail")' <<<"$last" >/dev/null 2>&1; then echo failed
        else echo whole; fi
    }
    unit="$(plan false)" journeys="$(plan true)"
    echo "→ unit tests: $unit, journeys: $journeys"
    failed() { [ "$1" = failed ] && echo --failed; }

    status=0
    just certify || status=1
    just ci-extra || status=1
    MIX_ENV=test mix ecto.create --quiet || exit 1
    MIX_ENV=test mix ecto.migrate || exit 1
    if [ "$unit" != skip ]; then
        MIX_ENV=test {{evidence}} run exunit -- {{exunit}} $(failed "$unit") || status=1
    fi
    if [ "$journeys" != skip ]; then
        MIX_ENV=test {{time_limit}} 120 10 "journey step" -- {{evidence}} run exunit -- {{exunit}} --seed 0 --include journey test/journeys/*_test.exs || status=1
    fi
    just journey-coverage || status=1
    exit "$status"
