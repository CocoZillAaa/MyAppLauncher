#!/bin/bash
set -euo pipefail
FRAMEWORK="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/Sparkle.framework"
[[ -d "$FRAMEWORK" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]] || { echo "Sparkle ou identité de signature indisponible." >&2; exit 1; }
# Preserve each Sparkle component's own entitlements; do not apply the host sandbox.
for component in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
    /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --preserve-metadata=entitlements "$FRAMEWORK/Versions/B/$component"
done
/usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime "$FRAMEWORK"
