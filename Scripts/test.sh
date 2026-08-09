#!/usr/bin/env bash
#
# Runs everything CI runs, in the same order, so a green local run means a green
# remote one.
#
#   Scripts/test.sh            packages + boundaries + lint, then the app if a
#                              simulator runtime is installed
#   Scripts/test.sh packages   packages only (fast; no Xcode needed beyond the toolchain)

set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=Scripts/env.sh
source Scripts/env.sh

scope="${1:-all}"

printf '\n── architectural boundaries ──────────────────────────\n'
Scripts/check-boundaries.sh

printf '\n── NutritionKit ──────────────────────────────────────\n'
swift test --package-path Packages/NutritionKit

printf '\n── LiftKit ───────────────────────────────────────────\n'
swift test --package-path Packages/LiftKit

if [ "$scope" = "packages" ]; then
    printf '\n✓ package tests passed\n'
    exit 0
fi

printf '\n── SwiftLint ─────────────────────────────────────────\n'
if command -v swiftlint >/dev/null 2>&1; then
    swiftlint lint --strict --quiet
    printf '  ✓ no violations\n'
else
    printf '  ! swiftlint not installed — brew install swiftlint\n'
fi

printf '\n── Caliper (iOS) ─────────────────────────────────────\n'
if ! command -v xcodegen >/dev/null 2>&1; then
    printf '  ! xcodegen not installed — brew install xcodegen\n'
    exit 1
fi
xcodegen generate --quiet

simulator=$(xcrun simctl list devices available -j 2>/dev/null \
    | /usr/bin/python3 -c '
import json, sys
try:
    devices = json.load(sys.stdin)["devices"]
except Exception:
    sys.exit(0)
for runtime, entries in sorted(devices.items()):
    if "iOS" not in runtime:
        continue
    for entry in entries:
        if entry.get("isAvailable") and "iPhone" in entry["name"]:
            print(entry["udid"])
            sys.exit(0)
')

if [ -z "$simulator" ]; then
    printf '  ! no iOS simulator runtime installed.\n'
    printf '    Install one with:  xcodebuild -downloadPlatform iOS\n'
    printf '    Skipping the app test run — package tests above still passed.\n'
    exit 1
fi

# Boot before testing. `xcodebuild test` will boot a shut-down device itself,
# but on a freshly installed runtime that race reliably loses — the launch fails
# preflight with "Busy" while the device is still coming up.
xcrun simctl bootstatus "$simulator" -b >/dev/null 2>&1 || true

log=$(mktemp -t caliper-xcodebuild)
trap 'rm -f "$log"' EXIT

if ! xcodebuild test \
    -project Caliper.xcodeproj \
    -scheme Caliper \
    -destination "id=${simulator}" > "$log" 2>&1
then
    grep -vE '^CoreData: error|\[error\] CoreData' "$log" | tail -40
    exit 1
fi

# A test bundle that fails to load reports "Executed 0 tests" and exits zero, so
# the exit code alone does not prove anything ran.
if ! grep -qE 'Test run with [1-9][0-9]* tests? in [0-9]+ suites? passed' "$log"; then
    printf '  ✗ no Swift Testing run was reported — the suite did not execute.\n'
    exit 1
fi

grep -oE 'Test run with [0-9]+ tests? in [0-9]+ suites? passed' "$log" | tail -1 | sed 's/^/  ✓ /'

printf '\n✓ all tests passed\n'
