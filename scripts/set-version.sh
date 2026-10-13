#!/bin/zsh
# Sets the app version to x.y.z.DDMMYY: MARKETING_VERSION = x.y.z, CURRENT_PROJECT_VERSION = today's date.
# Usage: scripts/set-version.sh [x.y.z]   (without an argument only the date is updated)
set -euo pipefail

cd "$(dirname "$0")/.."
PBXPROJ="bacisc-video-editor.xcodeproj/project.pbxproj"

if [[ $# -gt 0 ]]; then
    [[ "$1" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Version must look like 1.2.3" >&2; exit 1; }
    sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $1;/" "$PBXPROJ"
fi
DATE=$(date +%d%m%y)
sed -i '' -E "s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = $DATE;/" "$PBXPROJ"

VERSION=$(grep -m1 -E 'MARKETING_VERSION = ' "$PBXPROJ" | sed -E 's/.*= ([^;]+);/\1/')
echo "v$VERSION.$DATE"
