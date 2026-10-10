#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/myapplauncher-security.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
# Only the temporary source copy uses an isolated container. Production does
# not accept an environment variable or command-line override for App Group.
/usr/bin/sed 's/FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)/URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)/' \
  "$ROOT_DIR/Shared/SharedConfiguration.swift" > "$TEST_DIR/SharedConfiguration.swift"
/usr/bin/awk '{ print; if ($0 ~ /let configuration = URLSessionConfiguration.ephemeral/) print "        configuration.protocolClasses = [SecurityURLProtocol.self]" }' \
  "$ROOT_DIR/MyAppLauncher/ConfigurationStore.swift" > "$TEST_DIR/ConfigurationStore.swift"
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$TEST_DIR/ModuleCache" \
  "$ROOT_DIR/Shared/AppCatalog.swift" \
  "$ROOT_DIR/Shared/LaunchRouting.swift" \
  "$ROOT_DIR/Shared/WidgetGridLayout.swift" \
  "$ROOT_DIR/Shared/WidgetPagination.swift" \
  "$TEST_DIR/ConfigurationStore.swift" \
  "$TEST_DIR/SharedConfiguration.swift" \
  "$ROOT_DIR/Tests/SecurityNetworkFixtures.swift" \
  "$ROOT_DIR/Tests/SecurityTests.swift" -o "$TEST_DIR/SecurityTests"
"$TEST_DIR/SecurityTests" "$TEST_DIR/Data"
