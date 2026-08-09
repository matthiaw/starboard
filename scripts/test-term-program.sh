#!/usr/bin/env bash
# Checks that the panel's shell really receives TERM_PROGRAM=Starboard.
#
# macOS will not let one process read another's environment, so `ps eww` on the
# running panel's zsh returns nothing — asserting on the built binary's strings
# would only prove the literal is present, not that it arrives. Instead this
# launches the built app with a throwaway HOME whose .zshrc records what the
# child shell actually sees, which is the same code path the installed panel
# takes.
#
# Needs a window server session (a logged-in GUI), so it skips rather than fails
# when there is none.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BIN="$REPO_DIR/.build/release/Starboard.app/Contents/MacOS/Starboard"
FAILED=0

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; FAILED=1; }

echo "--- TERM_PROGRAM tests ---"

if [[ ! -x "$APP_BIN" ]]; then
    echo "  SKIP  $APP_BIN not built (run scripts/install.sh)"
    exit 0
fi
if ! launchctl print gui/"$(id -u)" >/dev/null 2>&1; then
    echo "  SKIP  no GUI session; cannot start the panel"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A login shell reads .zprofile then .zshrc; write both so the order cannot
# matter to the result.
cat > "$TMP/.zshrc" <<'EOF'
{ printf 'TERM_PROGRAM=%s\nTERM_PROGRAM_VERSION=%s\nSHELL=%s\nTERM=%s\n' \
    "${TERM_PROGRAM:-<unset>}" "${TERM_PROGRAM_VERSION:-<unset>}" \
    "${SHELL:-<unset>}" "${TERM:-<unset>}" > "$HOME/proof.txt"; } 2>/dev/null
EOF
cp "$TMP/.zshrc" "$TMP/.zprofile"

# Job control off, or bash prints "Terminated: 15" into the test output when the
# panel is killed below.
set +m
HOME="$TMP" "$APP_BIN" >/dev/null 2>&1 &
APP_PID=$!

for _ in $(seq 1 30); do
    [[ -f "$TMP/proof.txt" ]] && break
    kill -0 "$APP_PID" 2>/dev/null || break
    sleep 1
done
kill "$APP_PID" 2>/dev/null
wait "$APP_PID" 2>/dev/null

if [[ ! -f "$TMP/proof.txt" ]]; then
    fail "the panel's shell started" "no proof file; the app may not have launched"
    exit "$FAILED"
fi
pass "the panel's shell started and sourced its config"

got_program="$(grep '^TERM_PROGRAM=' "$TMP/proof.txt" | cut -d= -f2-)"
if [[ "$got_program" == "Starboard" ]]; then
    pass "TERM_PROGRAM=Starboard reaches the shell"
else
    fail "TERM_PROGRAM" "got '$got_program', want 'Starboard'"
fi

# Present only when the bundle carries a version, which install.sh takes from
# the VERSION file. A raw `swift build` without packaging has no Info.plist.
want_version="$(tr -d '[:space:]' < "$REPO_DIR/VERSION" 2>/dev/null || true)"
got_version="$(grep '^TERM_PROGRAM_VERSION=' "$TMP/proof.txt" | cut -d= -f2-)"
if [[ -n "$want_version" && "$got_version" == "$want_version" ]]; then
    pass "TERM_PROGRAM_VERSION=$got_version matches VERSION"
elif [[ "$got_version" == "<unset>" ]]; then
    pass "TERM_PROGRAM_VERSION absent (bundle carries no version) — not a failure"
else
    fail "TERM_PROGRAM_VERSION" "got '$got_version', VERSION says '$want_version'"
fi

# SHELL is set by the same append-if-absent mechanism; if it broke, the
# TERM_PROGRAM result above would be suspect too.
if [[ "$(grep '^SHELL=' "$TMP/proof.txt" | cut -d= -f2-)" == "/bin/zsh" ]]; then
    pass "SHELL is still set (same mechanism)"
else
    fail "SHELL" "$(grep '^SHELL=' "$TMP/proof.txt")"
fi

echo
if [[ "$FAILED" -eq 0 ]]; then
    echo "all TERM_PROGRAM tests passed"
else
    echo "TERM_PROGRAM tests FAILED"
fi
exit "$FAILED"
