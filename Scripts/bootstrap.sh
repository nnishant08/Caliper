#!/usr/bin/env bash
#
# Fresh-clone setup. Idempotent — run it whenever project.yml changes.

set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=Scripts/env.sh
source Scripts/env.sh

missing=()
command -v xcodegen  >/dev/null 2>&1 || missing+=(xcodegen)
command -v swiftlint >/dev/null 2>&1 || missing+=(swiftlint)

if [ ${#missing[@]} -gt 0 ]; then
    printf 'Missing build tools: %s\n' "${missing[*]}"
    printf 'Install with:  brew install %s\n' "${missing[*]}"
    exit 1
fi

if [ ! -d /Applications/Xcode.app ]; then
    printf 'Xcode is not installed at /Applications/Xcode.app.\n'
    exit 1
fi

xcodegen generate
printf '\n✓ Caliper.xcodeproj generated. Open it, or run Scripts/test.sh\n'
