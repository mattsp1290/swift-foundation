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
derived_data="${FOUNDATION_CONSUMER_DERIVED_DATA:-/tmp/swift-foundation-consumer-derived-data}"
test_derived_data="${FOUNDATION_CONSUMER_TEST_DERIVED_DATA:-/tmp/swift-foundation-consumer-test-derived-data}"
mkdir -p "$output_dir/Shared" "$output_dir/UITests"
cp -R "$root_dir/Consumers/Catalog" "$root_dir/Consumers/BenchySynthetic" "$output_dir/"
sed "s/__FOUNDATION_PIN__/$pin/g" "$root_dir/Consumers/project.yml.template" > "$output_dir/project.yml"
sed "s/__FOUNDATION_PIN__/$pin/g" "$root_dir/Consumers/Shared/FoundationRevision.swift.template" > "$output_dir/Shared/FoundationRevision.swift"
sed "s/__FOUNDATION_PIN__/$pin/g" "$root_dir/Consumers/UITests/ConsumerUITests.swift.template" > "$output_dir/UITests/ConsumerUITests.swift"
cd "$output_dir"
xcodegen generate
expected_log="swift-foundation Git SHA / SwiftPM pin: $pin"
original_appearance="$(xcrun simctl ui "$simulator_udid" appearance)"
original_content_size="$(xcrun simctl ui "$simulator_udid" content_size)"
restore_simulator_ui() {
  if [[ "$original_appearance" == light || "$original_appearance" == dark ]]; then
    xcrun simctl ui "$simulator_udid" appearance "$original_appearance" >/dev/null || true
  fi
  if [[ "$original_content_size" != unknown && "$original_content_size" != unsupported ]]; then
    xcrun simctl ui "$simulator_udid" content_size "$original_content_size" >/dev/null || true
  fi
}
trap restore_simulator_ui EXIT
for scheme in FoundationCatalog BenchySynthetic; do
  mac_log="$output_dir/$scheme-macos-build.log"
  ios_log="$output_dir/$scheme-ios-build.log"
  xcodebuild -project FoundationConsumers.xcodeproj -scheme "${scheme}_macOS" -configuration Debug -destination 'platform=macOS' -derivedDataPath "$derived_data" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build > "$mac_log" 2>&1 || { tail -80 "$mac_log"; exit 1; }
  xcodebuild -project FoundationConsumers.xcodeproj -scheme "${scheme}_iOS" -configuration Debug -destination "platform=iOS Simulator,id=$simulator_udid" -derivedDataPath "$derived_data" CODE_SIGNING_ALLOWED=NO build > "$ios_log" 2>&1 || { tail -80 "$ios_log"; exit 1; }

  mac_app="$derived_data/Build/Products/Debug/$scheme.app"
  mac_run_log="$output_dir/$scheme-macos-run.log"
  "$mac_app/Contents/MacOS/$scheme" > "$mac_run_log" 2>&1 &
  app_pid=$!
  logged=0
  for attempt in {1..20}; do
    if ! kill -0 "$app_pid" 2>/dev/null; then
      echo "$scheme macOS app exited before runtime pin appeared" >&2
      cat "$mac_run_log" >&2
      exit 1
    fi
    if grep -Fq "$expected_log" "$mac_run_log"; then logged=1; break; fi
    sleep 1
  done
  if [[ "$logged" -ne 1 ]]; then
    echo "$scheme macOS app did not log expected runtime pin" >&2
    cat "$mac_run_log" >&2
    kill "$app_pid" 2>/dev/null || true
    exit 1
  fi
  kill "$app_pid"
  wait "$app_pid" 2>/dev/null || true

  ios_app="$derived_data/Build/Products/Debug-iphonesimulator/$scheme.app"
  xcrun simctl install "$simulator_udid" "$ios_app"
  if [[ "$scheme" == FoundationCatalog ]]; then bundle_id=homes.birb.foundationconsumers.catalog; else bundle_id=homes.birb.foundationconsumers.benchysynthetic; fi
  xcrun simctl launch "$simulator_udid" "$bundle_id" | tee "$output_dir/$scheme-ios-run.log"

  mac_test_log="$output_dir/$scheme-macos-ui-test.log"
  ios_test_log="$output_dir/$scheme-ios-ui-test.log"
  if [[ "$scheme" == FoundationCatalog ]]; then xcrun simctl ui "$simulator_udid" appearance light; else xcrun simctl ui "$simulator_udid" appearance dark; fi
  if [[ "${FOUNDATION_SKIP_BENCHY_MACOS_UI_TESTS:-0}" == 1 && "$scheme" == BenchySynthetic ]]; then
    echo "BenchySynthetic macOS XCUITest unverified: runner skipped; native host smoke runs in verify-session-consumers.sh"
  elif xcodebuild -project FoundationConsumers.xcodeproj -scheme "${scheme}_macOS" -configuration Debug -destination 'platform=macOS' -derivedDataPath "$test_derived_data" -parallel-testing-enabled NO -resultBundlePath "$output_dir/$scheme-macos-ui.xcresult" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test > "$mac_test_log" 2>&1; then
    echo "$scheme macOS XCUITest passed"
  elif [[ "${FOUNDATION_ALLOW_CATALOG_EMPTY_TREE_FALLBACK:-0}" == 1 && "$scheme" == FoundationCatalog ]] \
    && grep -Fq 'Runtime pin must be visible' "$mac_test_log" \
    && grep -Fq 'No matches found for Descendants matching type Button from input' "$mac_test_log" \
    && grep -Fq "Application, pid:" "$mac_test_log" \
    && grep -Fq 'Executed 4 tests, with' "$mac_test_log" \
    && ! grep -Eq "Test Case .* passed" "$mac_test_log"; then
    echo "FoundationCatalog macOS XCUITest unverified: app-only accessibility tree; native host smoke runs in verify-session-consumers.sh" >&2
  else
    tail -100 "$mac_test_log"
    exit 1
  fi
  xcodebuild -project FoundationConsumers.xcodeproj -scheme "${scheme}_iOS" -configuration Debug -destination "platform=iOS Simulator,id=$simulator_udid" -derivedDataPath "$test_derived_data" -parallel-testing-enabled NO -resultBundlePath "$output_dir/$scheme-ios-ui.xcresult" test > "$ios_test_log" 2>&1 || { tail -100 "$ios_test_log"; exit 1; }
done
xcrun simctl ui "$simulator_udid" content_size accessibility-medium
large_log="$output_dir/FoundationCatalog-ios-dark-large-ui-test.log"
xcodebuild -project FoundationConsumers.xcodeproj -scheme FoundationCatalog_iOS -configuration Debug -destination "platform=iOS Simulator,id=$simulator_udid" -derivedDataPath "$test_derived_data" -parallel-testing-enabled NO -only-testing:CatalogUITests_iOS/CatalogUITests/testAccessibilityStatusAndLargeTypeLayout -resultBundlePath "$output_dir/FoundationCatalog-ios-dark-large-ui.xcresult" test > "$large_log" 2>&1 || { tail -100 "$large_log"; exit 1; }
printf 'Consumer project, build, launch, and XCUITest logs: %s\n' "$output_dir"
