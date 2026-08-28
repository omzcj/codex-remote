#!/bin/sh

set -eu

REPOSITORY_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$REPOSITORY_DIR"

sh -n codex-remote

expected_version="$(cat VERSION)"
actual_version="$(./codex-remote --version)"
[ "$actual_version" = "codex-remote $expected_version" ]
./codex-remote --help | grep -F "No LaunchAgent is installed or required" >/dev/null

(
  eval "$(sed '$d' codex-remote)"
  bootstrap_called=0
  # shellcheck disable=SC2329
  daemon_ready() { return 0; }
  # shellcheck disable=SC2329
  bootstrap_daemon() {
    bootstrap_called=1
    return 1
  }

  start_daemon
  [ "$bootstrap_called" -eq 0 ]
)

(
  eval "$(sed '$d' codex-remote)"
  daemon_available=0
  # shellcheck disable=SC2329
  daemon_ready() { [ "$daemon_available" -eq 1 ]; }
  # shellcheck disable=SC2329
  bootstrap_daemon() { daemon_available=1; }

  start_daemon
  [ "$daemon_available" -eq 1 ]
)
