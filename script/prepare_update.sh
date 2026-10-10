#!/bin/bash
set -euo pipefail
APP="${1:?Indiquer le bundle Release signé}"
TOOLS="${2:?Indiquer le dossier bin de la distribution officielle Sparkle 2.10.0}"
OUTPUT="${3:?Indiquer un dossier de publication}"
NOTES="${4:?Indiquer un fichier HTML de nouveautés FR/EN}"
[[ -d "$APP" && -x "$TOOLS/generate_appcast" && -f "$NOTES" ]] || exit 1
/usr/bin/codesign --verify --deep --strict "$APP"
INFO="$APP/Contents/Info.plist"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
[[ "$BUILD" =~ ^[0-9]+$ && "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")" == com.openai.MyAppLauncher ]] || exit 1
for child in PlugIns/MyAppLauncherWidget.appex XPCServices/WidgetMaintenance.xpc; do
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/$child/Contents/Info.plist")" == "$BUILD" ]] || exit 1
done
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "$INFO")" == true ]] || exit 1
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' "$INFO")" == true ]] || exit 1
mkdir -p "$OUTPUT"
ARCHIVE="MyAppLauncher-${VERSION}-build${BUILD}.zip"
[[ ! -e "$OUTPUT/$ARCHIVE" ]] || { echo "Archive déjà présente : utiliser un dossier vide pour un nouveau build." >&2; exit 1; }
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT/$ARCHIVE"
cp "$NOTES" "$OUTPUT/${ARCHIVE%.zip}.html"
# The private key stays in the login Keychain. Both feed and archive are signed.
"$TOOLS/generate_appcast" --account CocoZillAaa.MyAppLauncher --maximum-versions 1 --maximum-deltas 0 --embed-release-notes --download-url-prefix "https://github.com/CocoZillAaa/MyAppLauncher/releases/download/v${VERSION}-build${BUILD}/" --link https://github.com/CocoZillAaa/MyAppLauncher -o "$OUTPUT/appcast.xml" "$OUTPUT"
(cd "$OUTPUT" && /usr/bin/shasum -a 256 "$ARCHIVE" > SHA256SUMS.txt)
echo "Publication préparée : $OUTPUT"
echo "Publier le ZIP et SHA256SUMS.txt dans la Release v${VERSION}-build${BUILD}, puis updates/appcast.xml sur la branche main."
echo "Ne pas modifier appcast.xml après signature. Le dépôt doit être public pour la recherche intégrée sans jeton."
