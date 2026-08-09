#!/bin/bash
# Installs Starboard as a per-user LaunchAgent: starts it now, and arms it
# to start at every future login. Safe to re-run (e.g. after a rebuild) —
# it just rebuilds, repackages, and reloads it.
#
# Packages the binary into a minimal .app bundle and code-signs it with a
# local, self-signed certificate (created on first run, see below), rather
# than running the raw executable directly. This matters specifically for
# Accessibility permission (needed to track the Dock's geometry): a process
# launched by launchd (as this one is, once installed) has no "responsible"
# parent app to inherit trust from the way a process launched from Terminal
# does, so it needs its own stable TCC identity.
#
# Ad-hoc signing (`codesign --sign -`) is NOT enough for that stability,
# even with a fixed --identifier: with no real signing authority behind it,
# TCC still anchors trust to the binary's content hash under the hood, which
# changes on every rebuild. A certificate-based signature anchors trust to
# the certificate instead, which stays stable across rebuilds regardless of
# what changes in the code. It doesn't need to be a paid Apple Developer ID
# for this to work — a local, self-signed certificate is enough, since the
# binary only ever runs locally via launchd and is never distributed or
# downloaded (which is what Gatekeeper's stricter trust-chain checks are
# actually for).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.starboard.app"
CERT_NAME="Starboard Local Signing"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
BUILD_DIR="$REPO_DIR/.build/release"
BIN_PATH="$BUILD_DIR/Starboard"
# Installed out of the build tree on purpose. Two reasons, both about the
# Accessibility permission:
#
#   1. Adding an app to Privacy & Security -> Accessibility by hand goes through
#      a file picker, and .build is a dot-directory the picker hides unless you
#      know to press Cmd+Shift+period. ~/Applications is where it looks first.
#   2. `swift build` owns .build and may replace or remove what is in it. A
#      permission entry pointing there is aimed at a disposable path.
APP_DIR="$HOME/Applications"
APP_PATH="$APP_DIR/Starboard.app"
APP_BIN_PATH="$APP_PATH/Contents/MacOS/Starboard"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_PATH="$HOME/Library/Logs/Starboard.log"
# Read rather than duplicated, so TERM_PROGRAM_VERSION cannot drift from VERSION.
VERSION="$(tr -d '[:space:]' < "$REPO_DIR/VERSION" 2>/dev/null || echo "0")"

if ! security find-certificate -c "$CERT_NAME" "$LOGIN_KEYCHAIN" >/dev/null 2>&1; then
    echo "Creating local code-signing certificate ($CERT_NAME)..."
    echo "macOS will likely ask for your login password once, to confirm"
    echo "trusting this new certificate for code signing."
    CERT_DIR="$(mktemp -d)"
    trap 'rm -rf "$CERT_DIR"' EXIT

    openssl req -x509 -newkey rsa:2048 -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
        -days 3650 -nodes -subj "/CN=$CERT_NAME" \
        -addext "keyUsage=digitalSignature" \
        -addext "extendedKeyUsage=codeSigning" \
        -addext "basicConstraints=critical,CA:false"

    # -legacy: OpenSSL 3.x defaults to AES/SHA-256 for PKCS12, which
    # macOS's Security framework can't parse ("MAC verification failed")
    # -- it expects the older RC2/3DES-based format this flag restores.
    openssl pkcs12 -export -legacy -out "$CERT_DIR/cert.p12" \
        -inkey "$CERT_DIR/key.pem" -in "$CERT_DIR/cert.pem" -passout pass:starboard

    # -T grants codesign key access without a keychain-unlock prompt on
    # every future run.
    security import "$CERT_DIR/cert.p12" -k "$LOGIN_KEYCHAIN" \
        -P starboard -T /usr/bin/codesign -A

    # No -d: this trusts the cert for the *user's* login keychain only,
    # not system-wide, so it doesn't need sudo.
    security add-trusted-cert -r trustRoot -p codeSign \
        -k "$LOGIN_KEYCHAIN" "$CERT_DIR/cert.pem"

    echo "Certificate created and trusted for code signing."
fi

echo "Building release binary..."
(cd "$REPO_DIR" && swift build -c release)

echo "Packaging $APP_PATH..."
mkdir -p "$APP_DIR"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH" "$APP_BIN_PATH"
cp "$REPO_DIR/assets/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"

cat > "$APP_PATH/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$LABEL</string>
    <key>CFBundleName</key>
    <string>Starboard</string>
    <key>CFBundleExecutable</key>
    <string>Starboard</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

codesign --force --deep --sign "$CERT_NAME" --identifier "$LABEL" "$APP_PATH"

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_BIN_PATH</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_PATH</string>
    <key>StandardErrorPath</key>
    <string>$LOG_PATH</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

echo "Installed and started."
echo
echo "If the panel isn't tracking the Dock, check System Settings ->"
echo "Privacy & Security -> Accessibility for a \"Starboard\" entry and"
echo "make sure it's enabled — it should now persist across rebuilds."
echo
echo "Turn off (stops it now, and skips it at future logins):"
echo "  launchctl unload $PLIST_PATH"
echo
echo "Turn back on:"
echo "  launchctl load $PLIST_PATH"
echo
echo "Uninstall entirely: scripts/uninstall.sh"
