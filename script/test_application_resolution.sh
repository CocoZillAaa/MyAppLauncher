#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/myapplauncher-resolution.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
# Redirect the data container in a temporary copy only. The production app has
# no environment-based path override, and these tests cannot touch live data.
/usr/bin/sed 's/FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)/URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)/' \
  "$ROOT_DIR/Shared/SharedConfiguration.swift" > "$TEST_DIR/SharedConfiguration.swift"
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$TEST_DIR/ModuleCache" \
  "$ROOT_DIR/Shared/AppCatalog.swift" \
  "$ROOT_DIR/Shared/LaunchRouting.swift" \
  "$ROOT_DIR/MyAppLauncher/ConfigurationStore.swift" \
  "$TEST_DIR/SharedConfiguration.swift" \
  "$ROOT_DIR/Tests/ApplicationResolutionTests.swift" \
  -o "$TEST_DIR/ApplicationResolutionTests"
"$TEST_DIR/ApplicationResolutionTests" "$TEST_DIR/Data"
