#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! "$1" =~ ^[0-9a-f]{40}$ ]]; then
  echo 'usage: Scripts/verify-consumers.sh <40-character published swift-foundation Git SHA>' >&2
  exit 2
fi
command -v xcodegen >/dev/null || { echo 'Install XcodeGen (brew install xcodegen)' >&2; exit 2; }
root_dir="$(cd "$(dirname "$0")/.." && pwd)"
pin="$1"
simulator_udid="${FOUNDATION_SIMULATOR_UDID:-121ED81D-DC53-44DD-9031-B3A8429692DA}"
output_dir="${FOUNDATION_CONSUMER_OUTPUT:-$(mktemp -d /tmp/swift-foundation-consumers.XXXXXX)}"
mkdir -p "$output_dir/Shared"
cp -R "$root_dir/Consumers/Catalog" "$root_dir/Consumers/BenchySynthetic" "$output_dir/"
sed "s/__FOUNDATION_PIN__/$pin/g" "$root_dir/Consumers/project.yml.template" > "$output_dir/project.yml"
sed "s/__FOUNDATION_PIN__/$pin/g" "$root_dir/Consumers/Shared/FoundationRevision.swift.template" > "$output_dir/Shared/FoundationRevision.swift"
cd "$output_dir"
xcodegen generate
for scheme in FoundationCatalog BenchySynthetic; do
  xcodebuild -project FoundationConsumers.xcodeproj -scheme "${scheme}_macOS" -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath "$output_dir/DerivedData" CODE_SIGNING_ALLOWED=NO build > "$output_dir/$scheme-macos.log" 2>&1 || { tail -80 "$output_dir/$scheme-macos.log"; exit 1; }
  xcodebuild -project FoundationConsumers.xcodeproj -scheme "${scheme}_iOS" -configuration Debug -destination "platform=iOS Simulator,id=$simulator_udid" -derivedDataPath "$output_dir/DerivedData" CODE_SIGNING_ALLOWED=NO build > "$output_dir/$scheme-ios.log" 2>&1 || { tail -80 "$output_dir/$scheme-ios.log"; exit 1; }
  "$output_dir/DerivedData/Build/Products/Debug/$scheme.app/Contents/MacOS/$scheme" > "$output_dir/$scheme-macos-run.log" 2>&1 &
  app_pid=$!
  sleep 3
  kill "$app_pid" 2>/dev/null || true
  wait "$app_pid" 2>/dev/null || true
  xcrun simctl install "$simulator_udid" "$output_dir/DerivedData/Build/Products/Debug-iphonesimulator/$scheme.app"
  if [[ "$scheme" == FoundationCatalog ]]; then bundle_id=homes.birb.foundationconsumers.catalog; else bundle_id=homes.birb.foundationconsumers.benchysynthetic; fi
  xcrun simctl launch "$simulator_udid" "$bundle_id" | tee "$output_dir/$scheme-ios-run.log"
done
printf 'Consumer project, build logs, and launch logs: %s\n' "$output_dir"
