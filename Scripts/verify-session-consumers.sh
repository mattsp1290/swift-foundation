#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 0 ]]; then
  echo 'usage: Scripts/verify-session-consumers.sh' >&2
  exit 2
fi
root_dir="$(cd "$(dirname "$0")/.." && pwd)"
pin="$(git -C "$root_dir" rev-parse HEAD)"
if [[ -n "$(git -C "$root_dir" status --porcelain)" ]]; then
  echo 'Commit changes before immutable-pin verification' >&2
  exit 2
fi
if ! git ls-remote https://github.com/mattsp1290/swift-foundation.git \
  | awk -v pin="$pin" '$1 == pin { found = 1 } END { exit !found }'; then
  echo "The public remote does not advertise checked-out Git SHA $pin" >&2
  exit 2
fi
swift test
xcodebuild -scheme AuthenticatedHTTP -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
export FOUNDATION_CONSUMER_OUTPUT="${FOUNDATION_CONSUMER_OUTPUT:-$(mktemp -d /tmp/swift-foundation-session-consumers.XXXXXX)}"
FOUNDATION_SKIP_BENCHY_MACOS_UI_TESTS=1 FOUNDATION_ALLOW_CATALOG_EMPTY_TREE_FALLBACK=1 \
  "$root_dir/Scripts/verify-consumers.sh" "$pin"
derived_data="${FOUNDATION_CONSUMER_DERIVED_DATA:-/tmp/swift-foundation-consumer-derived-data}"
catalog_app="$derived_data/Build/Products/Debug/FoundationCatalog.app"
ben_chy_app="$derived_data/Build/Products/Debug/BenchySynthetic.app"
FOUNDATION_CATALOG_KEYCHAIN_SMOKE=1 "$catalog_app/Contents/MacOS/FoundationCatalog" \
  > "$FOUNDATION_CONSUMER_OUTPUT/Catalog-macos-keychain.log" 2>&1
grep -Fq 'Catalog Keychain smoke result: Keychain store, load, clear passed' \
  "$FOUNDATION_CONSUMER_OUTPUT/Catalog-macos-keychain.log"
"$root_dir/Scripts/verify-macos-keychain-host.sh" "$ben_chy_app" \
  > "$FOUNDATION_CONSUMER_OUTPUT/Benchy-macos-keychain.log"
FOUNDATION_FIXTURE_SMOKE_ACTION=session "$ben_chy_app/Contents/MacOS/BenchySynthetic" \
  > "$FOUNDATION_CONSUMER_OUTPUT/Benchy-macos-session.log" 2>&1
grep -Fq 'one refresh; two replays; revocation signed out' \
  "$FOUNDATION_CONSUMER_OUTPUT/Benchy-macos-session.log"
printf 'Session consumer contract passed for public Git SHA %s\n' "$pin"
