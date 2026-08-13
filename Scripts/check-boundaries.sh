#!/usr/bin/env bash
#
# Enforces the two architectural boundaries that the brief calls non-negotiable,
# by grep rather than by good intentions.
#
#   1. NutritionKit and LiftKit import no UI, no HealthKit, no database, and no
#      calendar arithmetic. This is what lets their tests run identically on
#      Linux and on device.
#   2. NutritionKit and LiftKit do not import each other, so the §7 decision to
#      either commit to the lift log or drop it stays cheap.
#
# Runs in CI on every push. If it fails, the fix is almost never to relax the
# list — see Docs/DECISIONS.md, ADR-0003 and ADR-0006.

set -euo pipefail

cd "$(dirname "$0")/.."

status=0

fail() {
    printf '\n  ✗ %s\n' "$1"
    status=1
}

# ── 1. Forbidden imports in the algorithm packages ──────────────────────────

forbidden_imports=(UIKit SwiftUI HealthKit SwiftData GRDB CoreData WidgetKit StoreKit)

for package in NutritionKit LiftKit; do
    sources="Packages/${package}/Sources"
    [ -d "$sources" ] || continue

    for module in "${forbidden_imports[@]}"; do
        if hits=$(grep -rn "^[[:space:]]*import[[:space:]]\+${module}\b" "$sources" 2>/dev/null); then
            fail "${package} imports ${module}:"
            printf '      %s\n' "$hits"
        fi
    done
done

# ── 2. Calendar arithmetic in the algorithm packages ────────────────────────
#
# swift-corelibs-foundation and Darwin Foundation diverge on Calendar and
# TimeZone. A package that does date-window arithmetic with these types can be
# green on the Linux CI job and wrong on a user's phone. Resolution belongs in
# App/Persistence/DayBoundary.swift, which the macOS job covers.

forbidden_date_types=(Calendar TimeZone DateComponents DateFormatter ISO8601DateFormatter)

for package in NutritionKit LiftKit; do
    sources="Packages/${package}/Sources"
    [ -d "$sources" ] || continue

    for symbol in "${forbidden_date_types[@]}"; do
        # Ignore comments and doc comments — these names appear in the rationale.
        if hits=$(grep -rn "\b${symbol}\b" "$sources" 2>/dev/null | grep -v '^\s*[^:]*:[0-9]*:\s*//'); then
            fail "${package} references ${symbol} outside a comment:"
            printf '      %s\n' "$hits"
        fi
    done
done

# ── 3. Cross-dependency between the algorithm packages ──────────────────────

if grep -rn "^[[:space:]]*import[[:space:]]\+LiftKit\b" Packages/NutritionKit/Sources 2>/dev/null; then
    fail "NutritionKit imports LiftKit. Shared code belongs in a third package."
fi

if grep -rn "^[[:space:]]*import[[:space:]]\+NutritionKit\b" Packages/LiftKit/Sources 2>/dev/null; then
    fail "LiftKit imports NutritionKit. Shared code belongs in a third package."
fi

# ── 4. The 5.1.3 boundary is not disabled wholesale ─────────────────────────
#
# A coarse backstop for the case where someone flips the local store to
# .automatic. The precise check is ModelSeparationTests; this one catches the
# edit that would make that test pass for the wrong reason.

if [ -f App/Persistence/CaliperModelContainer.swift ]; then
    local_store_line=$(grep -c 'cloudKitDatabase: .none' App/Persistence/CaliperModelContainer.swift || true)
    if [ "$local_store_line" -lt 1 ]; then
        fail "CaliperModelContainer no longer pins a store to cloudKitDatabase: .none (Guideline 5.1.3)."
    fi
fi

if [ "$status" -eq 0 ]; then
    printf '  ✓ architectural boundaries intact\n'
fi

exit "$status"
