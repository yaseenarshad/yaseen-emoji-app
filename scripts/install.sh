#!/bin/bash
# Puts "build/Yaseen Emoji.app" in /Applications and opens it.
#
# USAGE:
#   scripts/bundle.sh       First make the signed app.
#   scripts/install.sh      Then install it.
#
# The script quits the app that runs, replaces the app in /Applications, and
# opens the new one. It keeps no copy of the old app. The old versions are on
# the GitHub releases page.
#
# The first time, the script also imports your history from EmojiFinder (D6).
# It does this only if the EmojiFinder database exists and the app has no
# history at all: no you.json and no you-*.json in the default folder (D16).
# It reads a copy of the database, so the database of EmojiFinder never
# changes.
#
# The script changes /Applications. For that reason the owner of the Mac runs
# it, not an agent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Yaseen Emoji"
EXECUTABLE="YaseenEmoji"
SOURCE="$ROOT/build/$APP_NAME.app"
TARGET="/Applications/$APP_NAME.app"
# This finds each copy of the app that runs, also a copy outside /Applications.
RUNNING="/$APP_NAME.app/Contents/MacOS/$EXECUTABLE"
# The history of EmojiFinder, and the default folder of the history files of this app (D4, D6, D16).
OLD_DB="$HOME/Library/Containers/com.marioiannotta.searchmoji/Data/Documents/Database.sqlite"
YOU_DIR="$HOME/Library/Application Support/Yaseen Emoji"

# True if the app has any history: you.json (before D16), or a file of any Mac.
has_history() {
    [ -e "$YOU_DIR/you.json" ] && return 0
    local file
    for file in "$YOU_DIR"/you-*.json; do
        [ -e "$file" ] && return 0
    done
    return 1
}

[ -d "$SOURCE" ] || { echo "error: $SOURCE is missing. Run scripts/bundle.sh first." >&2; exit 1; }
codesign --verify --deep --strict "$SOURCE"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE/Contents/Info.plist")"

if pgrep -f "$RUNNING" >/dev/null; then
    echo "Quitting the app that runs."
    # This is the same as "Quit Yaseen Emoji" in the menu of the app.
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    # Wait until the old app is gone.
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        pgrep -f "$RUNNING" >/dev/null || break
        sleep 0.5
    done
    if pgrep -f "$RUNNING" >/dev/null; then
        echo "error: $APP_NAME still runs after 10 seconds. Quit it from its menu bar icon, then run this script again." >&2
        exit 1
    fi
fi

rm -rf "$TARGET"
ditto "$SOURCE" "$TARGET"
codesign --verify --deep --strict "$TARGET"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET/Contents/Info.plist")"

# Import the EmojiFinder history one time, before the app opens and reads its history.
if [ -f "$OLD_DB" ] && ! has_history; then
    echo "Importing your history from EmojiFinder."
    mkdir -p "$YOU_DIR"
    # The query reads a copy. A plain open of the real file can write the -wal
    # file back into the database when it closes.
    COPY_DIR="$(mktemp -d)"
    trap 'rm -rf "$COPY_DIR"' EXIT
    for PART in "$OLD_DB" "$OLD_DB-wal" "$OLD_DB-shm"; do
        if [ -f "$PART" ]; then cp "$PART" "$COPY_DIR/"; fi
    done
    OLD_COPY="$COPY_DIR/$(basename "$OLD_DB")"
    if sqlite3 -json "$OLD_COPY" "SELECT e.ZEMOJI AS emoji, u.ZCOUNT AS count FROM ZEMOJIUSAGE u JOIN ZEMOJI e ON e.Z_PK = u.ZEMOJI" \
        | "$TARGET/Contents/MacOS/$EXECUTABLE" --import-uses "$YOU_DIR"; then
        echo "Imported your EmojiFinder history into $YOU_DIR."
    else
        # The app is installed. It has no history file, so the next run tries again.
        echo "WARNING: the import of the EmojiFinder history failed. Run this script again to try again." >&2
    fi
    rm -rf "$COPY_DIR"
    trap - EXIT
fi

open "$TARGET"
echo "Done. $APP_NAME $VERSION is in /Applications and is open."

# Both apps use ⌘E. If both run, only one of them gets the key (D6).
if pgrep -x EmojiFinder >/dev/null; then
    echo "WARNING: EmojiFinder is running. It also uses ⌘E. Quit it and remove it from your login items."
fi
