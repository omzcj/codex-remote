#!/bin/sh

set -eu

REPOSITORY_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$REPOSITORY_DIR"

sh -n codex-remote

expected_version="$(cat VERSION)"
actual_version="$(./codex-remote --version)"
[ "$actual_version" = "codex-remote $expected_version" ]

help_output="$(./codex-remote --help)"
for command_name in status start stop restart update; do
  printf '%s\n' "$help_output" | grep -F "$command_name" >/dev/null
done
printf '%s\n' "$help_output" | grep -F "Running without a command is read-only" >/dev/null
if printf '%s\n' "$help_output" | grep -E '^[[:space:]]+(enable|reset)' >/dev/null; then exit 1; fi
for removed_command in enable reset; do
  set +e
  removed_output="$(./codex-remote "$removed_command" 2>&1)"
  removed_status=$?
  set -e
  [ "$removed_status" -ne 0 ]
  printf '%s\n' "$removed_output" | grep -F "unknown command: $removed_command" >/dev/null
done

# Source the implementation without dispatching a real command.
CODEX_REMOTE_SOURCE_ONLY=1
export CODEX_REMOTE_SOURCE_ONLY
. ./codex-remote

[ "$(json_string_field '{"status":"running","backend":"pid"}' backend)" = "pid" ]
[ -z "$(json_string_field '{"status":"running"}' backend)" ]

# Color is applied only by the renderer; neutral fields remain byte-for-byte plain.
(
  COLOR_RED='<red>'
  COLOR_YELLOW='<yellow>'
  COLOR_GREEN='<green>'
  COLOR_RESET='</color>'
  [ "$(print_status_field state unmanaged error)" = 'state: <red>unmanaged</color>' ]
  [ "$(print_status_field state stopped warning)" = 'state: <yellow>stopped</color>' ]
  [ "$(print_status_field state healthy good)" = 'state: <green>healthy</color>' ]
  [ "$(print_status_field codex-remote 2026.09.08.6 neutral)" = 'codex-remote: 2026.09.08.6' ]
)

# Issue lines are highlighted while an empty issue list is green.
(
  COLOR_RED='<red>'
  COLOR_GREEN='<green>'
  COLOR_RESET='</color>'
  STATUS_ISSUE_COUNT=0
  [ "$(print_issue broken)" = '<red>- broken</color>' ]
)

# start writes both Sparkle preferences and is idempotent once they are false.
(
  automatic_checks=1
  automatic_install=1
  sparkle_environment=""
  writes=""
  gui_launchctl() {
    case "$1" in
      getenv) printf '%s\n' "$sparkle_environment" ;;
      setenv) sparkle_environment="$3" ;;
      *) return 1 ;;
    esac
  }
  desktop_preference_value() {
    case "$1" in
      SUEnableAutomaticChecks) printf '%s\n' "$automatic_checks" ;;
      SUAutomaticallyUpdate) printf '%s\n' "$automatic_install" ;;
    esac
  }
  write_false_desktop_preference() {
    writes="${writes}$1 "
    case "$1" in
      SUEnableAutomaticChecks) automatic_checks=0 ;;
      SUAutomaticallyUpdate) automatic_install=0 ;;
    esac
  }
  disable_desktop_auto_updates
  [ "$AUTO_UPDATE_CHANGED" = yes ]
  [ "$sparkle_environment" = false ]
  [ "$writes" = "SUEnableAutomaticChecks SUAutomaticallyUpdate " ]
  writes=""
  disable_desktop_auto_updates
  [ "$AUTO_UPDATE_CHANGED" = no ]
  [ -z "$writes" ]
)

# Subsequent command tests isolate lifecycle behavior from the real preferences.
disable_desktop_auto_updates() {
  AUTO_UPDATE_CHANGED=no
  DESKTOP_AUTO_UPDATES=disabled
}

# Reuse settings must target the GUI bootstrap domain even when invoked by SSH.
(
  observed=""
  gui_environment_value() { [ "$1" = "TEST_VALUE" ] && printf '1\n'; }
  gui_launchctl_mutate() { observed="$*"; }
  [ "$(gui_launchctl getenv TEST_VALUE)" = "1" ]
  gui_launchctl setenv TEST_VALUE 1
  [ "$observed" = "setenv TEST_VALUE 1" ]
  gui_launchctl unsetenv TEST_VALUE
  [ "$observed" = "unsetenv TEST_VALUE" ]
)

# Newer daemon probes omit backend. Strong process and path evidence must still
# identify the official remote-control daemon without accepting a plain server.
(
  CODEX_HOME_DIR=/tmp/codex-test-home
  CONTROL_SOCKET="$CODEX_HOME_DIR/app-server-control/app-server-control.sock"
  DAEMON_BACKEND=""
  DAEMON_STATUS=running
  DAEMON_SOCKET_PATH="$CONTROL_SOCKET"
  DAEMON_MANAGED_CODEX_PATH="$CODEX_HOME_DIR/packages/standalone/current/codex"
  SERVER_EXECUTABLE="$CODEX_HOME_DIR/packages/standalone/releases/0.153.4-aarch64-apple-darwin/bin/codex"
  SERVER_COMMAND="$CODEX_HOME_DIR/packages/standalone/current/codex app-server --remote-control --listen unix://"
  probe_identifies_managed_daemon
  SERVER_COMMAND="$CODEX_HOME_DIR/packages/standalone/current/codex app-server --listen unix://"
  if probe_identifies_managed_daemon; then exit 1; fi
)

# The legacy pid backend remains authoritative for older Codex releases.
(
  DAEMON_BACKEND=pid
  DAEMON_STATUS=""
  DAEMON_SOCKET_PATH=""
  DAEMON_MANAGED_CODEX_PATH=""
  SERVER_EXECUTABLE=""
  SERVER_COMMAND=""
  probe_identifies_managed_daemon
)

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
  DESKTOP_AUTO_UPDATES=disabled
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

# status reports every independent problem without asking the user to compose a plan.
combined_status_output="$( (
  CHATGPT_APP=/Applications/ChatGPT.app
  CHATGPT_VERSION=26.901.51231
  DESKTOP_COMPATIBILITY=unverified
  MANAGED_VERSION=0.153.4
  RUNNING_VERSION=0.153.4
  CLI_VERSION=0.153.4
  DAEMON_OWNERSHIP=unmanaged
  UPDATER_STATE=stopped
  REUSE_ENABLED=no
  CHATGPT_PIDS=""
  DESKTOP_BACKEND=inactive
  print_issues
) )"
printf '%s\n' "$combined_status_output" | grep -F "ChatGPT Desktop 26.901.51231 is unverified" >/dev/null
printf '%s\n' "$combined_status_output" | grep -F "an unmanaged app-server owns the control socket" >/dev/null
printf '%s\n' "$combined_status_output" | grep -F "Desktop daemon reuse is disabled" >/dev/null
printf '%s\n' "$combined_status_output" | grep -F "ChatGPT Desktop is not running" >/dev/null
if printf '%s\n' "$combined_status_output" | grep -F "recommended recovery" >/dev/null; then exit 1; fi

# A missing Desktop is reported as a fact without a recovery menu.
missing_desktop_output="$( (
  CHATGPT_APP=/Applications/ChatGPT.app
  DESKTOP_COMPATIBILITY=missing
  MANAGED_VERSION=0.153.4
  RUNNING_VERSION=0.153.4
  CLI_VERSION=0.153.4
  DAEMON_OWNERSHIP=managed
  UPDATER_STATE=stopped
  REUSE_ENABLED=yes
  CHATGPT_PIDS=""
  DESKTOP_BACKEND=inactive
  print_issues
) )"
printf '%s\n' "$missing_desktop_output" | grep -F "ChatGPT Desktop is not installed" >/dev/null
if printf '%s\n' "$missing_desktop_output" | grep -F "brew install" >/dev/null; then exit 1; fi

# A healthy state must not invent recovery work.
healthy_status_output="$( (
  DESKTOP_COMPATIBILITY=verified
  DESKTOP_AUTO_UPDATES=disabled
  MANAGED_VERSION=0.153.4
  RUNNING_VERSION=0.153.4
  CLI_VERSION=0.153.4
  DAEMON_OWNERSHIP=managed
  UPDATER_STATE=stopped
  REUSE_ENABLED=yes
  CHATGPT_PIDS=42
  DESKTOP_BACKEND=managed-daemon
  print_issues
) )"
printf '%s\n' "$healthy_status_output" | grep -F -- "- none" >/dev/null

# status reports update preferences without directing repair.
auto_update_status_output="$( (
  DESKTOP_COMPATIBILITY=verified
  DESKTOP_AUTO_UPDATES=not-disabled
  MANAGED_VERSION=0.153.4
  RUNNING_VERSION=0.153.4
  CLI_VERSION=0.153.4
  DAEMON_OWNERSHIP=managed
  UPDATER_STATE=stopped
  REUSE_ENABLED=yes
  CHATGPT_PIDS=42
  DESKTOP_BACKEND=managed-daemon
  print_issues
) )"
printf '%s\n' "$auto_update_status_output" | grep -F "ChatGPT Desktop automatic updates are not disabled" >/dev/null

# The internal attach stage must refuse an unmanaged app-server instead of guessing.
set +e
attach_error="$( (
  require_macos() { :; }
  find_managed_codex() { MANAGED_CODEX_BIN=/usr/bin/true; return 0; }
  collect_state() {
    DESKTOP_COMPATIBILITY=verified
    DAEMON_OWNERSHIP=unmanaged
  }
  CHATGPT_APP=/tmp
  start_managed_reuse
) 2>&1)"
attach_status=$?
set -e
[ "$attach_status" -ne 0 ]
printf '%s\n' "$attach_error" | grep -F "runtime ownership changed" >/dev/null

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
  start_managed_reuse
) 2>&1)"
missing_backend_status=$?
set -e
[ "$missing_backend_status" -ne 0 ]
printf '%s\n' "$missing_backend_error" | grep -F "did not own the control socket" >/dev/null

# A healthy internal attach is idempotent and must not restart either process.
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
  start_managed_reuse
)

# A failed preference write blocks start with one concrete reason.
set +e
auto_update_error="$( (
  require_macos() { :; }
  ensure_start_prerequisites() { :; }
  disable_desktop_auto_updates() { return 1; }
  CHATGPT_APP=/tmp
  command_start
) 2>&1)"
auto_update_status=$?
set -e
[ "$auto_update_status" -ne 0 ]
printf '%s\n' "$auto_update_error" | grep -F "failed to disable ChatGPT Desktop automatic updates" >/dev/null

# A healthy start does not stop or reattach the managed runtime.
(
  require_macos() { :; }
  collect_state() {
    DESKTOP_COMPATIBILITY=verified
    MANAGED_VERSION=0.153.4
    CLI_VERSION=0.153.4
    DAEMON_OWNERSHIP=managed
    UPDATER_STATE=stopped
    OVERALL_STATE=healthy
  }
  command_stop() { exit 1; }
  start_managed_reuse() { exit 1; }
  command_start
)

# start repairs a safely identified unmanaged runtime, enables reuse, and verifies it.
(
  order=""
  runtime_phase=unmanaged
  require_macos() { :; }
  collect_state() {
    DESKTOP_COMPATIBILITY=verified
    MANAGED_VERSION=0.153.4
    CLI_VERSION=0.153.4
    UPDATER_STATE=stopped
    case "$runtime_phase" in
      unmanaged)
        DAEMON_OWNERSHIP=unmanaged
        SERVER_PID=42
        OVERALL_STATE=unmanaged
        REUSE_ENABLED=no
        DESKTOP_BACKEND=inactive
        ;;
      stopped)
        DAEMON_OWNERSHIP=stopped
        SERVER_PID=""
        OVERALL_STATE=stopped
        REUSE_ENABLED=no
        DESKTOP_BACKEND=inactive
        ;;
      managed)
        DAEMON_OWNERSHIP=managed
        SERVER_PID=42
        REUSE_ENABLED=yes
        DESKTOP_BACKEND=managed-daemon
        OVERALL_STATE=healthy
        ;;
    esac
  }
  socket_owner_pids() { printf '42\n'; }
  process_start_time() { printf 'Sat Sep  6 12:00:00 2026\n'; }
  is_safe_app_server_pid() { [ "$1" = 42 ]; }
  command_stop() { order="${order}stop "; runtime_phase=stopped; }
  start_managed_reuse() { order="${order}attach "; runtime_phase=managed; }
  command_start
  [ "$order" = "stop attach " ]
)

# A non-pinned Desktop is restored automatically through the pinned cask.
(
  collect_count=0
  require_macos() { :; }
  brew_available() { return 0; }
  desktop_cask_installed() { return 0; }
  brew() { [ "$*" = "reinstall --cask omzcj/omzcj/chatgpt" ]; }
  collect_state() {
    collect_count=$((collect_count + 1))
    if [ "$collect_count" -eq 1 ]; then
      DESKTOP_COMPATIBILITY=unverified
    else
      DESKTOP_COMPATIBILITY=verified
    fi
  }
  ensure_pinned_desktop
)

# Missing or skewed standalone Codex installs converge to the resolved release.
(
  collect_count=0
  require_macos() { :; }
  collect_state() {
    collect_count=$((collect_count + 1))
    if [ "$collect_count" -eq 1 ]; then
      CLI_VERSION=""
      MANAGED_VERSION=""
    else
      CLI_VERSION=0.153.4
      MANAGED_VERSION=0.153.4
    fi
  }
  latest_release_version() { printf '0.153.4\n'; }
  install_release() { [ "$1" = "0.153.4" ]; }
  ensure_standalone_codex
)

# Missing Homebrew is called out before the pinned Desktop install command.
set +e
missing_brew_output="$( (
  require_macos() { :; }
  brew_available() { return 1; }
  collect_state() {
    DESKTOP_COMPATIBILITY=missing
    MANAGED_VERSION=0.153.4
    CLI_VERSION=0.153.4
    DAEMON_OWNERSHIP=stopped
    UPDATER_STATE=stopped
  }
  command_start
) 2>&1)"
missing_brew_status=$?
set -e
[ "$missing_brew_status" -ne 0 ]
printf '%s\n' "$missing_brew_output" | grep -F "Homebrew is required to install the pinned ChatGPT Desktop" >/dev/null

# Unknown socket ownership is diagnostic-only; start must not terminate it.
set +e
unknown_owner_output="$( (
  require_macos() { :; }
  collect_state() {
    DESKTOP_COMPATIBILITY=verified
    MANAGED_VERSION=0.153.4
    CLI_VERSION=0.153.4
    DAEMON_OWNERSHIP=unmanaged
    SERVER_PID=42
    SERVER_EXECUTABLE=/tmp/unrelated/codex
    SERVER_COMMAND='/tmp/unrelated/codex app-server --listen unix://'
    UPDATER_STATE=stopped
  }
  socket_owner_pids() { printf '42\n'; }
  process_start_time() { printf 'Sat Sep  6 12:00:00 2026\n'; }
  is_safe_app_server_pid() { return 1; }
  command_stop() { exit 1; }
  command_start
) 2>&1)"
unknown_owner_status=$?
set -e
[ "$unknown_owner_status" -ne 0 ]
printf '%s\n' "$unknown_owner_output" | grep -F "cannot safely replace control-socket owner PID(s): 42" >/dev/null

# Ambiguous updater ownership is also diagnostic-only.
set +e
unknown_updater_output="$( (
  require_macos() { :; }
  collect_state() {
    DESKTOP_COMPATIBILITY=verified
    MANAGED_VERSION=0.153.4
    CLI_VERSION=0.153.4
    DAEMON_OWNERSHIP=managed
    UPDATER_STATE=ambiguous
    UPDATER_PID=73
  }
  command_stop() { exit 1; }
  command_start
) 2>&1)"
unknown_updater_status=$?
set -e
[ "$unknown_updater_status" -ne 0 ]
printf '%s\n' "$unknown_updater_output" | grep -F "cannot safely replace standalone updater state: ambiguous" >/dev/null

# restart checks safety first, then performs ensure-stopped and closed-loop start.
(
  order=""
  assert_safe_to_converge() { order="${order}safety "; }
  command_stop() { order="${order}stop "; }
  command_start() { order="${order}start:$* "; }
  command_restart
  [ "$order" = "safety stop start: " ]
)

# A hard restart blocker is reported before anything is stopped.
set +e
restart_blocked_output="$( (
  assert_safe_to_converge() { fail "cannot safely replace control-socket owner PID(s): 42"; }
  command_stop() { exit 99; }
  command_restart
) 2>&1)"
restart_blocked_status=$?
set -e
[ "$restart_blocked_status" -eq 1 ]
printf '%s\n' "$restart_blocked_output" | grep -F "cannot safely replace control-socket owner PID(s): 42" >/dev/null

# The internal attach stage must open and verify Desktop when it was initially stopped.
(
  order=""
  require_macos() { :; }
  find_managed_codex() { MANAGED_CODEX_BIN=/usr/bin/true; MANAGED_VERSION=0.153.4; return 0; }
  collect_state() {
    DESKTOP_COMPATIBILITY=verified
    OVERALL_STATE=waiting-for-desktop
    DAEMON_OWNERSHIP=managed
    MANAGED_VERSION=0.153.4
    RUNNING_VERSION=0.153.4
    CHATGPT_PIDS=""
  }
  enable_reuse() { order="${order}reuse "; }
  open_chatgpt() { order="${order}open "; }
  wait_for_desktop_attach() { order="${order}verify "; }
  CHATGPT_APP=/tmp
  start_managed_reuse
  [ "$order" = "reuse open verify " ]
)

# update closes and restores an active runtime without asking for a stop command.
(
  order=""
  require_macos() { :; }
  valid_release() { return 0; }
  assert_safe_to_converge() { :; }
  collect_state() {
    DAEMON_OWNERSHIP=managed
    CHATGPT_PIDS=42
    REUSE_ENABLED=yes
    RUNNING_VERSION=0.153.4
  }
  command_stop() { order="${order}stop "; }
  install_release() { order="${order}install:$1 "; }
  find_managed_codex() { MANAGED_CODEX_BIN=/bin/true; return 0; }
  codex_version() { printf '0.153.4\n'; }
  command_start() { order="${order}start "; }
  command_update 0.153.4
  [ "$order" = "stop install:0.153.4 start " ]
)

# latest is resolved once and the installer receives the exact version.
(
  require_macos() { :; }
  assert_safe_to_converge() { :; }
  find_managed_codex() { MANAGED_CODEX_BIN=/bin/true; return 0; }
  collect_state() {
    DAEMON_OWNERSHIP=stopped
    CHATGPT_PIDS=""
    REUSE_ENABLED=no
  }
  latest_release_version() { printf '0.153.4\n'; }
  command_stop() { :; }
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

# stop must stop the updater before considering app-server cleanup.
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
  command_stop
  [ "$order" = "disable updater cleanup " ]
)

# A successful stop leaves Desktop stopped so start cannot race a new direct server.
(
  collect_count=0
  require_macos() { :; }
  collect_state() {
    collect_count=$((collect_count + 1))
    if [ "$collect_count" -eq 1 ]; then CHATGPT_PIDS=42; else CHATGPT_PIDS=""; fi
    DAEMON_OWNERSHIP=stopped
    SERVER_PID=""
    UPDATER_STATE=stopped
    DESKTOP_BACKEND=inactive
  }
  disable_reuse() { :; }
  stop_chatgpt() { :; }
  stop_updater() { :; }
  cleanup_runtime_records() { :; }
  open_chatgpt() { exit 1; }
  command_stop
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
  command_stop
)

# A stale socket has no live process and must not block a standalone-only update.
(
  require_macos() { :; }
  assert_safe_to_converge() { :; }
  find_managed_codex() { MANAGED_CODEX_BIN=/usr/bin/true; return 0; }
  collect_state() {
    DAEMON_OWNERSHIP=stale-socket
    CHATGPT_PIDS=""
    REUSE_ENABLED=no
  }
  command_stop() { :; }
  install_release() { [ "$1" = "0.153.4" ]; }
  codex_version() { printf '0.153.4\n'; }
  command_update 0.153.4
)

echo "tests passed"
