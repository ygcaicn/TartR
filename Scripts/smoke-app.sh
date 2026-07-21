#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
ZIP="$ROOT/outputs/TartR-$VERSION-macos.zip"
FAKE_TART="$ROOT/Tests/Fixtures/fake-tart.sh"
WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/tartr-smoke.XXXXXX")"
APP="$WORK/TartR.app"
HOME_DIR="$WORK/home"
STATE_DIR="$WORK/fake-state"
TART_HOME_DIR="$WORK/tart-home"
FAKE_LOG="$WORK/fake-tart.log"
APP_STDOUT="$WORK/app.stdout"
VM_STDOUT="$WORK/vm.stdout"
APP_PID=""
VM_PID=""
RUNNING_VM="smoke-running"
AUTOSTART_VM="smoke-autostart"
SMOKE_LANGUAGE="${TARTR_SMOKE_LANGUAGE:-en}"

cleanup() {
  if [[ -n "$APP_PID" ]] && /bin/kill -0 "$APP_PID" 2>/dev/null; then
    /bin/kill -TERM "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  local pid_file managed_pid
  for pid_file in "$STATE_DIR"/*.pid(N); do
    managed_pid="$(<"$pid_file")"
    /bin/kill -TERM "$managed_pid" 2>/dev/null || true
  done
  if [[ -n "$VM_PID" ]] && /bin/kill -0 "$VM_PID" 2>/dev/null; then
    /bin/kill -TERM "$VM_PID" 2>/dev/null || true
    wait "$VM_PID" 2>/dev/null || true
  fi
  /bin/rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

fail() {
  print -u2 -- "TartR smoke test failed: $1"
  [[ ! -f "$FAKE_LOG" ]] || /bin/cat "$FAKE_LOG" >&2
  [[ ! -f "$APP_STDOUT" ]] || /bin/cat "$APP_STDOUT" >&2
  exit 1
}

wait_for() {
  local description="$1"
  shift
  local attempt
  for attempt in {1..100}; do
    if "$@"; then return 0; fi
    /bin/sleep 0.1
  done
  fail "timed out waiting for $description"
}

app_pids() {
  /usr/bin/pgrep -x TartR 2>/dev/null || true
}

has_app_process() {
  [[ -n "$(app_pids)" ]]
}

list_count() {
  [[ -f "$FAKE_LOG" ]] || { print 0; return; }
  local count
  count="$(/usr/bin/grep -c '^list$' "$FAKE_LOG" 2>/dev/null || true)"
  print "${count:-0}"
}

has_list_count_at_least() {
  [[ "$(list_count)" -ge "$1" ]]
}

has_list_count_greater_than() {
  [[ "$(list_count)" -gt "$1" ]]
}

[[ -f "$ZIP" ]] || fail "missing $ZIP; run make build first"
[[ -x "$FAKE_TART" ]] || fail "fake Tart is not executable"
[[ -z "$(/usr/bin/pgrep -x TartR 2>/dev/null || true)" ]] \
  || fail "another TartR process is already running"

/bin/mkdir -p "$HOME_DIR" "$STATE_DIR" "$TART_HOME_DIR"
/usr/bin/ditto -x -k "$ZIP" "$WORK"
/usr/bin/xattr -cr "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

CFFIXED_USER_HOME="$HOME_DIR" HOME="$HOME_DIR" \
  /usr/bin/swift "$ROOT/Tests/Fixtures/SeedVMPreferences.swift" \
    --tart-home "$TART_HOME_DIR" "$RUNNING_VM" "$AUTOSTART_VM"

TART_HOME="$TART_HOME_DIR" FAKE_TART_STATE_DIR="$STATE_DIR" FAKE_TART_LOG="$FAKE_LOG" \
  FAKE_TART_VMS="$RUNNING_VM $AUTOSTART_VM" \
  "$FAKE_TART" run "$RUNNING_VM" > "$VM_STDOUT" 2>&1 &
VM_PID=$!
wait_for "fake VM startup" /bin/test -f "$STATE_DIR/$RUNNING_VM.pid"

CFFIXED_USER_HOME="$HOME_DIR" HOME="$HOME_DIR" \
  TART_EXECUTABLE="$FAKE_TART" \
  FAKE_TART_STATE_DIR="$STATE_DIR" FAKE_TART_LOG="$FAKE_LOG" \
  FAKE_TART_VMS="$RUNNING_VM $AUTOSTART_VM" \
  "$APP/Contents/MacOS/TartR" -AppleLanguages "($SMOKE_LANGUAGE)" > "$APP_STDOUT" 2>&1 &
APP_PID=$!
wait_for "TartR process" has_app_process
[[ "$APP_PID" != *$'\n'* ]] || fail "more than one TartR instance launched"
wait_for "initial state synchronization" has_list_count_at_least 1
wait_for "configured VM autostart" /bin/test -f "$STATE_DIR/$AUTOSTART_VM.pid"
INITIAL_LIST_COUNT="$(list_count)"

/usr/bin/open -g "$APP"
wait_for "reopen state synchronization" has_list_count_greater_than "$INITIAL_LIST_COUNT"
[[ "$(app_pids)" == "$APP_PID" ]] || fail "reopening created another TartR instance"
[[ "$(/usr/bin/grep -c "^run-invoked: $RUNNING_VM$" "$FAKE_LOG")" == 1 ]] \
  || fail "TartR attempted to start an already-running VM"
[[ "$(/usr/bin/grep -c "^run-invoked: $AUTOSTART_VM$" "$FAKE_LOG")" == 1 ]] \
  || fail "TartR did not autostart the configured stopped VM exactly once"
[[ "$(/usr/bin/grep '^tart-home:' "$FAKE_LOG" | /usr/bin/sort -u)" == "tart-home: $TART_HOME_DIR" ]] \
  || fail "TartR did not apply the persisted TART_HOME to every Tart process"

print "TartR packaged app smoke test passed for $SMOKE_LANGUAGE (PID $APP_PID, list syncs: $(list_count))."
