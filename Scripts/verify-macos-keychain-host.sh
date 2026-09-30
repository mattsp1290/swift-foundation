#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo 'usage: Scripts/verify-macos-keychain-host.sh <BenchySynthetic.app>' >&2
  exit 2
fi

executable="$1/Contents/MacOS/BenchySynthetic"
if [[ ! -x "$executable" ]]; then
  echo "Missing BenchySynthetic executable: $executable" >&2
  exit 2
fi

check() {
  local action="$1" expected="$2" output
  output="$(FOUNDATION_FIXTURE_SMOKE_ACTION="$action" "$executable")"
  if [[ "$output" != *"Fixture smoke result: $expected"* ]]; then
    echo "Fixture smoke $action failed: $output" >&2
    exit 1
  fi
  echo "$action: $expected"
}

check clear 'Signed out'
check login 'fixture-alice'
check restore 'fixture-alice'
check replace 'fixture-bob'
check restore 'fixture-bob'
check clear 'Signed out'
check restore 'Signed out'
