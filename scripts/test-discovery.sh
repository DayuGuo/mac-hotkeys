#!/bin/bash
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/mac-hotkeys-test.XXXXXXXX")
trap 'rm -rf "$work"' EXIT

cd "$root"
xcrun swiftc -module-cache-path "$work/cache" \
    Keys.swift Inventory.swift InstalledApp.swift ApplicationReaders.swift KarabinerRules.swift \
    ActiveEventMonitor.swift ActiveScan.swift DiscoveryHistory.swift tests/discovery/main.swift \
    -o "$work/test-discovery"
"$work/test-discovery" "$work/state"
