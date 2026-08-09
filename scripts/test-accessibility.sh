#!/usr/bin/env bash
# Checks grant-accessibility.sh --check, and that Starboard reports its trust
# state at all.
#
# The --check path is driven against log fixtures rather than the real log, so
# the result does not depend on whether this machine happens to have the
# permission granted.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/grant-accessibility.sh"
FAILED=0

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; FAILED=1; }

echo "--- accessibility tests ---"

# check <name> <log contents> <expected state> <expected exit>
check() {
    local name="$1" contents="$2" want_state="$3" want_exit="$4"
    local log; log="$(mktemp)"
    printf '%s' "$contents" > "$log"
    local got_state got_exit
    got_state="$(STARBOARD_LOG="$log" "$SCRIPT" --check 2>/dev/null)"
    got_exit=$?
    rm -f "$log"
    if [[ "$got_state" == "$want_state" && "$got_exit" -eq "$want_exit" ]]; then
        pass "$name"
    else
        fail "$name" "got '$got_state' exit $got_exit, want '$want_state' exit $want_exit"
    fi
}

check "granted is reported as granted, exit 0" \
    'starboard: accessibility trusted = yes' granted 0
check "denied is reported as denied, exit 1" \
    'starboard: accessibility trusted = no' denied 1
check "an empty log is unknown, exit 2" \
    '' unknown 2
check "an unrelated log is unknown, exit 2" \
    'some other line' unknown 2

# launchd appends, so a log spanning several launches must answer for the last.
check "the newest line wins (no then yes)" \
    'starboard: accessibility trusted = no
starboard: accessibility trusted = yes' granted 0
check "the newest line wins (yes then no)" \
    'starboard: accessibility trusted = yes
starboard: accessibility trusted = no' denied 1

# A missing log file is the same as an unreadable one: unknown, not a crash.
missing="$(STARBOARD_LOG=/nonexistent/starboard.log "$SCRIPT" --check 2>/dev/null)"
if [[ "$missing" == "unknown" ]]; then
    pass "a missing log is unknown, not an error"
else
    fail "a missing log" "got '$missing'"
fi

# --check must have no side effects: no System Settings, no Finder, no restart.
# Proven by the absence of the guided flow's own output.
guided="$(STARBOARD_LOG=/nonexistent/x "$SCRIPT" --check 2>&1)"
if grep -qiE 'Opening System Settings|Revealing the app|Press Return' <<< "$guided"; then
    fail "--check has no side effects" "the guided flow ran: $guided"
else
    pass "--check does not open settings, Finder, or prompt"
fi

if [[ "$("$SCRIPT" --nonsense >/dev/null 2>&1; echo $?)" -eq 2 ]]; then
    pass "an unknown argument exits 2 with usage"
else
    fail "unknown argument" "expected exit 2"
fi

# ---- and the other half: does the app actually report a state? ----
# Without this the parser above could be perfect and still have nothing to read.
REAL_LOG="$HOME/Library/Logs/Starboard.log"
if [[ ! -f "$HOME/Library/LaunchAgents/com.starboard.app.plist" ]]; then
    echo "  SKIP  not installed; cannot check that the app reports its state"
elif ! launchctl print gui/"$(id -u)" >/dev/null 2>&1; then
    echo "  SKIP  no GUI session"
else
    : > "$REAL_LOG" 2>/dev/null || true
    launchctl kickstart -k "gui/$(id -u)/com.starboard.app" >/dev/null 2>&1
    for _ in $(seq 1 15); do
        grep -q 'accessibility trusted' "$REAL_LOG" 2>/dev/null && break
        sleep 1
    done
    if grep -q 'accessibility trusted = \(yes\|no\)' "$REAL_LOG" 2>/dev/null; then
        pass "the running app reports its trust state ($("$SCRIPT" --check))"
    else
        fail "the app reports its trust state" "nothing in $REAL_LOG after a restart"
    fi
fi

echo
if [[ "$FAILED" -eq 0 ]]; then
    echo "all accessibility tests passed"
else
    echo "accessibility tests FAILED"
fi
exit "$FAILED"
