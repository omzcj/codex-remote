#!/bin/sh

set -eu

REPOSITORY_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$REPOSITORY_DIR"

sh -n codex-remote

expected_version="$(cat VERSION)"
actual_version="$(./codex-remote --version)"
[ "$actual_version" = "codex-remote $expected_version" ]

help_output="$(./codex-remote --help)"
for command_name in status enable reset update; do
  printf '%s\n' "$help_output" | grep -F "$command_name" >/dev/null
done
printf '%s\n' "$help_output" | grep -F "Running without a command is read-only" >/dev/null

# Source the implementation without dispatching a real command.
CODEX_REMOTE_SOURCE_ONLY=1
export CODEX_REMOTE_SOURCE_ONLY
. ./codex-remote

[ "$(json_string_field '{"status":"running","backend":"pid"}' backend)" = "pid" ]
[ -z "$(json_string_field '{"status":"running"}' backend)" ]

# No arguments must dispatch to the read-only status command.
(
  called=""
  command_status() { called="status"; }
  main
  [ "$called" = "status" ]
)

assert_classification() {
  DAEMON_OWNERSHIP="$1"
  REUSE_ENABLED="$2"
  CHATGPT_PIDS="$3"
  DESKTOP_BACKEND="$4"
  DESKTOP_COMPATIBILITY="$5"
  MANAGED_VERSION="$6"
  RUNNING_VERSION="$7"
  expected_state="$8"
  classify_state
  [ "$OVERALL_STATE" = "$expected_state" ] || {
    echo "expected $expected_state, got $OVERALL_STATE" >&2
    exit 1
  }
}

assert_classification unmanaged no "" inactive verified 0.153.4 0.152.1 unmanaged
assert_classification stale-socket no "" inactive verified "" "" stale-socket
assert_classification managed-unready yes "" inactive verified 0.153.4 "" starting-unready
assert_classification managed yes 42 managed-daemon verified 0.153.4 0.152.1 version-skew
assert_classification managed yes 42 managed-daemon verified 0.153.4 0.153.4 healthy
assert_classification managed no 42 not-managed-daemon verified 0.153.4 0.153.4 disabled
assert_classification stopped yes "" inactive verified 0.153.4 "" stopped
assert_classification managed yes 42 managed-daemon unverified 0.153.4 0.153.4 unsupported-desktop

# enable must refuse an unmanaged app-server instead of guessing at lifecycle actions.
set +e
enable_error="$( (
  require_macos() { :; }
  find_managed_codex() { MANAGED_CODEX_BIN=/usr/bin/true; return 0; }
  collect_state() {
    DESKTOP_COMPATIBILITY=verified
    DAEMON_OWNERSHIP=unmanaged
  }
  CHATGPT_APP=/tmp
  command_enable
) 2>&1)"
enable_status=$?
set -e
[ "$enable_status" -ne 0 ]
printf '%s\n' "$enable_error" | grep -F "run codex-remote reset first" >/dev/null

# A successful daemon start is insufficient if the follow-up probe has no pid backend.
set +e
missing_backend_error="$( (
  require_macos() { :; }
  find_managed_codex() { MANAGED_CODEX_BIN=/usr/bin/true; return 0; }
  collect_count=0
  collect_state() {
    collect_count=$((collect_count + 1))
    DESKTOP_COMPATIBILITY=verified
    OVERALL_STATE=stopped
    if [ "$collect_count" -eq 1 ]; then DAEMON_OWNERSHIP=stopped; else DAEMON_OWNERSHIP=unmanaged; fi
  }
  CHATGPT_APP=/tmp
  command_enable
) 2>&1)"
missing_backend_status=$?
set -e
[ "$missing_backend_status" -ne 0 ]
printf '%s\n' "$missing_backend_error" | grep -F "daemon is not managed" >/dev/null

# A healthy enable is idempotent and must not restart either process.
(
  require_macos() { :; }
  find_managed_codex() { MANAGED_CODEX_BIN=/usr/bin/true; return 0; }
  collect_state() {
    DESKTOP_COMPATIBILITY=verified
    OVERALL_STATE=healthy
    DAEMON_OWNERSHIP=managed
  }
  enable_reuse() { exit 1; }
  stop_chatgpt() { exit 1; }
  CHATGPT_APP=/tmp
  command_enable
)

# update must apply the same unmanaged guard before invoking the installer.
set +e
update_error="$( (
  require_macos() { :; }
  valid_release() { return 0; }
  find_managed_codex() { MANAGED_CODEX_BIN=/usr/bin/true; return 0; }
  collect_state() { DAEMON_OWNERSHIP=unmanaged; }
  command_update 0.153.4
) 2>&1)"
update_status=$?
set -e
[ "$update_status" -ne 0 ]
printf '%s\n' "$update_error" | grep -F "run codex-remote reset first" >/dev/null

# latest is resolved once and the installer receives the exact version.
(
  require_macos() { :; }
  find_managed_codex() { MANAGED_CODEX_BIN=/bin/true; return 0; }
  collect_state() {
    DAEMON_OWNERSHIP=stopped
    CHATGPT_PIDS=""
    REUSE_ENABLED=no
  }
  latest_release_version() { printf '0.153.4\n'; }
  stop_updater() { :; }
  remove_stale_pid_file() { :; }
  install_release() { [ "$1" = "0.153.4" ]; }
  codex_version() { printf '0.153.4\n'; }
  command_update latest
)

# A reused stale updater PID is ignored rather than killed or treated as live.
(
  pid_record_is_live() { return 1; }
  orphan_updater_pids() { return 0; }
  terminate_updater() { exit 1; }
  stop_updater
)

# An unmanaged process is killable only when UID, start time, socket, executable,
# and command line all identify the exact standalone app-server.
(
  CODEX_HOME_DIR=/tmp/codex-test-home
  pid_alive() { [ "$1" = 42 ]; }
  process_uid() { /usr/bin/id -u; }
  process_start_time() { printf 'Sat Sep  6 12:00:00 2026\n'; }
  single_socket_owner_pid() { printf '42\n'; }
  process_executable() { printf '%s\n' "$CODEX_HOME_DIR/packages/standalone/releases/0.153.4-aarch64-apple-darwin/bin/codex"; }
  process_command() { printf '%s\n' "$HOME/.local/bin/codex app-server --listen unix://"; }
  is_safe_app_server_pid 42 'Sat Sep  6 12:00:00 2026'
  if is_safe_app_server_pid 43 'Sat Sep  6 12:00:00 2026'; then exit 1; fi
  process_executable() { printf '/tmp/unrelated/codex\n'; }
  if is_safe_app_server_pid 42 'Sat Sep  6 12:00:00 2026'; then exit 1; fi
)

# reset must stop the updater before considering app-server cleanup.
(
  order=""
  require_macos() { :; }
  collect_state() {
    CHATGPT_PIDS=""
    DAEMON_OWNERSHIP=stopped
    SERVER_PID=""
    UPDATER_STATE=stopped
    DESKTOP_BACKEND=inactive
  }
  disable_reuse() { order="${order}disable "; }
  stop_updater() { order="${order}updater "; }
  cleanup_runtime_records() { order="${order}cleanup "; }
  command_reset
  [ "$order" = "disable updater cleanup " ]
)

# A valid but unready managed PID must still be stopped through the official lifecycle.
(
  collect_count=0
  require_macos() { :; }
  collect_state() {
    collect_count=$((collect_count + 1))
    CHATGPT_PIDS=""
    UPDATER_STATE=stopped
    DESKTOP_BACKEND=inactive
    MANAGED_CODEX_BIN=/usr/bin/true
    if [ "$collect_count" -le 2 ]; then
      DAEMON_OWNERSHIP=managed-unready
      SERVER_PID=42
    else
      DAEMON_OWNERSHIP=stopped
      SERVER_PID=""
    fi
  }
  disable_reuse() { :; }
  stop_updater() { :; }
  cleanup_runtime_records() { :; }
  command_reset
)

# A stale socket has no live process and must not block a standalone-only update.
(
  require_macos() { :; }
  find_managed_codex() { MANAGED_CODEX_BIN=/usr/bin/true; return 0; }
  collect_state() {
    DAEMON_OWNERSHIP=stale-socket
    CHATGPT_PIDS=""
    REUSE_ENABLED=no
  }
  stop_updater() { :; }
  remove_stale_pid_file() { :; }
  install_release() { [ "$1" = "0.153.4" ]; }
  codex_version() { printf '0.153.4\n'; }
  command_update 0.153.4
)

echo "tests passed"
