#!/bin/bash
# Stops Starboard and removes it as a login item.
set -euo pipefail

LABEL="com.starboard.app"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
APP_PATH="$HOME/Applications/Starboard.app"

launchctl unload "$PLIST_PATH" 2>/dev/null || true
rm -f "$PLIST_PATH"
echo "Removed login item ($PLIST_PATH)."

if [ -d "$APP_PATH" ]; then
    rm -rf "$APP_PATH"
    echo "Removed $APP_PATH."
fi

# Left alone deliberately: the Accessibility entry in System Settings (only a
# human can remove that), the local signing certificate in the login keychain
# (shared with any future reinstall), and ~/.config/starboard/config.json, which
# is the user's, not ours.
echo
echo "Still there, on purpose: the Accessibility entry, the signing"
echo "certificate, and ~/.config/starboard/config.json."
