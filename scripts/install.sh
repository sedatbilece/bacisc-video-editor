#!/bin/zsh
# Builds a Release archive and installs the app into /Applications.
set -euo pipefail

cd "$(dirname "$0")/.."
SCHEME="bacisc-video-editor"
ARCHIVE="build/${SCHEME}.xcarchive"
APP_NAME="${SCHEME}.app"

rm -rf "$ARCHIVE"
xcodebuild -scheme "$SCHEME" -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" archive -quiet

APP="$ARCHIVE/Products/Applications/$APP_NAME"
[[ -d "$APP" ]] || { echo "Archive did not contain $APP_NAME" >&2; exit 1; }

# Quit a running copy before replacing it.
osascript -e "tell application id \"sedatbilece.bacisc-video-editor\" to quit" 2>/dev/null || true

rm -rf "/Applications/$APP_NAME"
ditto "$APP" "/Applications/$APP_NAME"
echo "Installed /Applications/$APP_NAME"
open "/Applications/$APP_NAME"
