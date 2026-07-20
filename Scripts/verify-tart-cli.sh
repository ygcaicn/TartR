#!/bin/zsh
set -euo pipefail

TART_BIN="${TART_EXECUTABLE:-$(command -v tart 2>/dev/null || true)}"
if [[ -z "$TART_BIN" || ! -x "$TART_BIN" ]]; then
  print -u2 "Tart executable is required for CLI compatibility verification."
  exit 2
fi

require_help() {
  local command="$1"
  shift
  local output
  if output="$("$TART_BIN" "$command" --help 2>&1)"; then
    :
  else
    local exit_code=$?
    print -u2 "Unable to read 'tart $command --help' (status $exit_code)."
    [[ -z "$output" ]] || print -u2 -- "$output"
    exit 1
  fi
  local expected
  for expected in "$@"; do
    if [[ "$output" != *"$expected"* ]]; then
      print -u2 "tart $command is missing expected option: $expected"
      exit 1
    fi
  done
}

require_help list --source --format
require_help run --no-graphics --no-audio --no-clipboard
if [[ "$(uname -m)" == "arm64" ]]; then require_help run --suspendable; fi
require_help stop --timeout
require_help clone
require_help rename
require_help delete
require_help ip --wait
require_help suspend
require_help exec
require_help get --format
require_help push
require_help import
require_help export
require_help prune --entries --older-than --space-budget
require_help set --cpu --memory --display --disk-size
require_help create --from-ipsw --linux --disk-size

print "Compatible Tart CLI: $("$TART_BIN" --version)"
