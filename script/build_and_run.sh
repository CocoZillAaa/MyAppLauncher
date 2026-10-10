#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR"
BUILD_DIR="$ROOT_DIR/work/DerivedData"
APP_BUNDLE="$PROJECT_DIR/Install/MyAppLauncher.app"
MODE="${1:-run}"
if [[ "$MODE" == "--install-release-built" ]]; then
    APP_BUNDLE='/Applications/MyAppLauncher.app'
fi
LSREGISTER='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'

stop_process() {
    local process_name="$1" status=0
    /usr/bin/pkill -x "$process_name" || status=$?
    if [[ "$status" -gt 1 ]]; then
        echo "Impossible d’arrêter $process_name. Relancer avec les droits locaux nécessaires." >&2
        exit "$status"
    fi
    for attempt in {1..20}; do
        if ! /usr/bin/pgrep -x "$process_name" >/dev/null; then return; fi
        sleep 0.1
    done
    echo "$process_name est encore actif. Arrêter la session Xcode avant l’installation." >&2
    exit 1
}

if [[ "$MODE" == "--install-built" || "$MODE" == "--install-release-built" ]]; then
    SOURCE_BUNDLE="${2:?Indiquer le chemin du bundle compilé par Xcode}"
else
    mkdir -p "$ROOT_DIR/work"
    BUILD_CONFIGURATION=Debug
    BUILD_LOG="$ROOT_DIR/work/build.log"
    if [[ "$MODE" == "--release-build-only" ]]; then
        BUILD_CONFIGURATION=Release
        BUILD_DIR="$ROOT_DIR/work/DerivedData-release"
        BUILD_LOG="$ROOT_DIR/work/build-release.log"
    fi
    xcodebuild -project "$PROJECT_DIR/MyAppLauncher.xcodeproj" -scheme MyAppLauncher -configuration "$BUILD_CONFIGURATION" -destination 'generic/platform=macOS' -derivedDataPath "$BUILD_DIR" build > "$BUILD_LOG" 2>&1 || { tail -60 "$BUILD_LOG"; exit 1; }
    SOURCE_BUNDLE="$BUILD_DIR/Build/Products/$BUILD_CONFIGURATION/MyAppLauncher.app"
fi
[[ "$SOURCE_BUNDLE" != "$APP_BUNDLE" ]] || { echo "Le bundle source doit être distinct de la copie installée." >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$SOURCE_BUNDLE"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_BUNDLE/Contents/Info.plist")" == 'com.openai.MyAppLauncher' ]] || exit 1
if [[ "$MODE" == "--release-build-only" ]]; then
    echo "Release compilée et signée : $SOURCE_BUNDLE"
    exit 0
fi
mkdir -p "$PROJECT_DIR/Install"
STAGED_BUNDLE="$PROJECT_DIR/Install/.MyAppLauncher-new.app"
if [[ "$MODE" == "--install-release-built" ]]; then
    # Stage on the destination volume so the final rename is atomic.
    STAGED_BUNDLE='/Applications/.MyAppLauncher-new.app'
fi
rm -rf "$STAGED_BUNDLE"
/usr/bin/ditto "$SOURCE_BUNDLE" "$STAGED_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$STAGED_BUNDLE"
stop_process MyAppLauncher
stop_process MyAppLauncherWidget
if [[ -d "$APP_BUNDLE" ]]; then
    BACKUP_DIR="$(mktemp -d "$ROOT_DIR/work/launcher-install-backup.XXXXXX")"
    /usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$BACKUP_DIR/MyAppLauncher.zip"
    rm -rf "$APP_BUNDLE"
fi
mv "$STAGED_BUNDLE" "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

# Une seule copie enregistrée, pour le widget et pour les liens de lancement.
while IFS= read -r extension_path; do
    [[ "$extension_path" == "$APP_BUNDLE/Contents/PlugIns/MyAppLauncherWidget.appex" ]] && continue
    /usr/bin/pluginkit -r "$extension_path"
    "$LSREGISTER" -u "${extension_path%/Contents/PlugIns/MyAppLauncherWidget.appex}"
done < <(/usr/bin/pluginkit -m -A -D -v -i com.openai.MyAppLauncher.widget | awk -F '\t' '$NF ~ /^\// {print $NF}')
"$LSREGISTER" -f "$APP_BUNDLE"
/usr/bin/pluginkit -a "$APP_BUNDLE/Contents/PlugIns/MyAppLauncherWidget.appex"
if [[ "$MODE" == "--build-only" ]]; then exit 0; fi
/usr/bin/open "$APP_BUNDLE"
case "$MODE" in
  --verify) sleep 1; /usr/bin/pgrep -x MyAppLauncher ;;
  --logs|--telemetry) /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.openai.MyAppLauncher"' ;;
  --debug) lldb -n MyAppLauncher ;;
esac
