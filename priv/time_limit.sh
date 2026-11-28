#!/usr/bin/env bash
# time_limit.sh LIMIT GRACE NAME -- COMMAND...
#
# Runs COMMAND; if it is still running after LIMIT seconds, sends SIGTERM to it
# and everything under it, then SIGKILL to whatever is left GRACE seconds later,
# and exits 124 saying NAME timed out. Otherwise exits with COMMAND's status.
#
# Plain bash because macOS has no `timeout`. The whole tree, not only the pid:
# under `mix test` the work is a beam, a Playwright driver and a Chromium the
# driver puts in a session of its own, and a hung `mix test` has been seen to
# ignore SIGTERM (issue ci-journey-step-has-a-time-limit).
set -uo pipefail

limit="$1" grace="$2" name="$3"
shift 3
[ "${1:-}" = "--" ] && shift

tree() {
  local child
  echo "$1"
  for child in $(pgrep -P "$1"); do tree "$child"; done
}

signal_tree() {
  local pids
  pids="$(tree "$2")"
  # shellcheck disable=SC2086
  kill "-$1" $pids 2>/dev/null || true
}

# The tree as it stands, plus every pid in $1 still alive and its tree: a
# child whose parent died of SIGTERM is reparented and no longer under it.
survivors() {
  local p
  for p in $1; do kill -0 "$p" 2>/dev/null && tree "$p"; done
}

flag="$(mktemp)"
rm -f "$flag"

"$@" &
pid=$!

(
  sleep "$limit"
  kill -0 "$pid" 2>/dev/null || exit 0
  : > "$flag"
  pids="$(tree "$pid")"
  # shellcheck disable=SC2086
  kill -TERM $pids 2>/dev/null
  sleep "$grace"
  # shellcheck disable=SC2086
  kill -KILL $(survivors "$pids") 2>/dev/null
  exit 0
) &
watcher=$!

wait "$pid"
status=$?

if [ -e "$flag" ]; then
  # The command's own pid is gone; anything it left (a Chromium in its own
  # session) was in the tree the watcher signalled. Let the watcher finish.
  wait "$watcher" 2>/dev/null || true
  rm -f "$flag"
  echo "ci: the $name timed out after ${limit}s and was killed" >&2
  exit 124
fi

signal_tree KILL "$watcher"
wait "$watcher" 2>/dev/null || true
exit "$status"
