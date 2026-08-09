#!/bin/bash
# Walks you through granting Starboard the Accessibility permission, and tells
# you afterwards whether it actually took.
#
# It cannot grant it. Nothing can, short of disabling SIP: the TCC database is
# protected, and `tccutil` only resets entries, never creates them. That is the
# point of the mechanism — a program that could grant itself Accessibility could
# read every keystroke on the machine.
#
# What this does instead is remove every other obstacle: it reports the current
# state from a source you can check, opens the exact settings pane, reveals the
# app so it can be dragged in, and verifies the result by restarting Starboard
# and reading what it reports about itself.
set -uo pipefail

LABEL="com.starboard.app"
APP_PATH="$HOME/Applications/Starboard.app"
# Overridable so the test suite can point it at a fixture instead of the real log.
LOG_PATH="${STARBOARD_LOG:-$HOME/Library/Logs/Starboard.log}"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"

bold=$'\033[1m'; dim=$'\033[2m'; green=$'\033[32m'; yellow=$'\033[33m'; red=$'\033[31m'; reset=$'\033[0m'
[[ -t 1 ]] || { bold=""; dim=""; green=""; yellow=""; red=""; reset=""; }

say()  { printf '%s\n' "$*"; }
step() { printf '\n%s%s%s\n' "$bold" "$*" "$reset"; }

# Starboard writes `accessibility trusted = yes|no` to stderr at every launch,
# and the LaunchAgent sends stderr here. That is the only reliable read: TCC.db
# needs Full Disk Access to query, and AXIsProcessTrusted only answers for the
# calling process, not for another app.
trust_state() {
    local line
    line="$(grep 'accessibility trusted' "$LOG_PATH" 2>/dev/null | tail -1)"
    case "$line" in
        *"= yes") echo granted ;;
        *"= no")  echo denied ;;
        *)        echo unknown ;;
    esac
}

restart_and_read() {
    : > "$LOG_PATH" 2>/dev/null || true
    if [[ -f "$PLIST_PATH" ]]; then
        launchctl kickstart -k "gui/$(id -u)/$LABEL" >/dev/null 2>&1
    else
        say "${yellow}No login item at $PLIST_PATH — run scripts/install.sh first.${reset}"
        return 1
    fi
    # The state line is written in init(), so it lands almost immediately; give
    # launchd a moment regardless.
    local waited=0
    while [[ "$(trust_state)" == unknown && "$waited" -lt 15 ]]; do
        sleep 1
        waited=$((waited + 1))
    done
    trust_state
}

# --check: report the state and exit, no side effects and no prompts. For
# scripts, and for asking the question without being walked through an answer.
#   0 granted   1 denied   2 unknown
if [[ "${1:-}" == "--check" ]]; then
    state="$(trust_state)"
    echo "$state"
    case "$state" in
        granted) exit 0 ;;
        denied)  exit 1 ;;
        *)       exit 2 ;;
    esac
fi

if [[ -n "${1:-}" ]]; then
    say "usage: $(basename "$0") [--check]"
    exit 2
fi

say "${bold}Starboard — Accessibility permission${reset}"
say "${dim}Needed to read the Dock's geometry. Without it Starboard still runs,"
say "it just sits at a fixed corner instead of flush against the Dock.${reset}"

if [[ ! -d "$APP_PATH" ]]; then
    say ""
    say "${red}$APP_PATH does not exist.${reset}"
    say "Run scripts/install.sh first — it builds and installs the bundle there."
    exit 1
fi

step "1. Current state"
state="$(restart_and_read)"
case "$state" in
    granted)
        say "${green}Already granted.${reset} Starboard reports accessibility trusted = yes."
        say "Nothing to do. If the panel still is not flush against the Dock, the"
        say "cause is elsewhere: a left/right Dock or a Dock on a secondary display"
        say "is deliberately not tracked."
        exit 0
        ;;
    denied)
        say "${yellow}Not granted.${reset} Starboard reports accessibility trusted = no."
        ;;
    *)
        say "${yellow}Could not read the state${reset} from $LOG_PATH."
        say "Continuing anyway — the steps below are harmless if it is already granted."
        ;;
esac

step "2. Opening System Settings"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
say "Privacy & Security → Accessibility should be open now."

step "3. Revealing the app"
open -R "$APP_PATH"
say "A Finder window is showing ${bold}Starboard.app${reset} in ~/Applications."

step "4. What to do there"
say "  ${bold}a)${reset} Is there already a \"Starboard\" row?"
say "     Switch it ${bold}on${reset}. If it is already on but the panel is not tracking"
say "     the Dock, ${bold}remove${reset} the row with \"−\" and add it again — an entry from"
say "     an older build can look enabled while no longer being valid."
say "  ${bold}b)${reset} No row? Drag Starboard.app from the Finder window into the list,"
say "     or use \"+\" and pick ~/Applications/Starboard.app."
say ""
say "${dim}The app is installed in ~/Applications rather than in the build"
say "directory precisely so this step works: the file picker hides"
say "dot-directories like .build unless you press Cmd+Shift+period.${reset}"

step "5. Press Return here once you have done it"
read -r _ </dev/tty || true

step "6. Verifying"
say "Restarting Starboard so the new permission takes effect..."
state="$(restart_and_read)"
case "$state" in
    granted)
        say ""
        say "${green}Granted.${reset} Starboard reports accessibility trusted = yes."
        say "The panel now tracks the Dock's geometry."
        exit 0
        ;;
    denied)
        say ""
        say "${red}Still not granted.${reset} Starboard reports accessibility trusted = no."
        say ""
        say "The usual causes, in order of likelihood:"
        say "  · the row was added but not switched on"
        say "  · a stale row from an earlier install — remove it with \"−\", then re-add"
        say "  · a different Starboard.app was added (an old .build copy, say);"
        say "    the one that matters is ${bold}$APP_PATH${reset}"
        say ""
        say "Run this script again after fixing it."
        exit 1
        ;;
    *)
        say ""
        say "${yellow}Could not verify.${reset} $LOG_PATH has no state line."
        say "Check that the login item is loaded:  launchctl list | grep starboard"
        exit 1
        ;;
esac
