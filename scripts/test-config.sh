#!/usr/bin/env bash
# Checks the config file: that valid keys are accepted, that broken ones are
# reported instead of crashing, and that the panel still starts either way.
#
# Runs the real built app with XDG_CONFIG_HOME pointed at a throwaway directory
# and reads its stderr, which is where StarboardConfig.load() reports problems
# (and where the LaunchAgent sends it, ~/Library/Logs/Starboard.log).
#
# Needs a window server session, so it skips rather than fails without a GUI.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0

# Rebuild first, then test the FRESH binary — not the copy inside
# .build/release/Starboard.app, which install.sh puts there and which is stale
# until the next install. Testing that copy silently checks the previous build,
# which is how the first version of this suite "passed" while reporting nothing.
if command -v swift >/dev/null 2>&1; then
    (cd "$REPO_DIR" && swift build -c release >/dev/null 2>&1) \
        || echo "  note  swift build failed; testing the existing binary"
fi
APP_BIN="$REPO_DIR/.build/release/Starboard"
[[ -x "$APP_BIN" ]] || APP_BIN="$REPO_DIR/.build/release/Starboard.app/Contents/MacOS/Starboard"

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; FAILED=1; }

echo "--- config tests ---"

if [[ ! -x "$APP_BIN" ]]; then
    echo "  SKIP  not built (swift build -c release)"
    exit 0
fi
if ! launchctl print gui/"$(id -u)" >/dev/null 2>&1; then
    echo "  SKIP  no GUI session; cannot start the panel"
    exit 0
fi

set +m

# run_with <json> -> prints the app's stderr. An empty first argument writes no
# config file at all, which is the no-config case.
run_with() {
    local json="$1"
    local dir; dir="$(mktemp -d)"
    if [[ -n "$json" ]]; then
        mkdir -p "$dir/starboard"
        printf '%s' "$json" > "$dir/starboard/config.json"
    fi
    local err; err="$(mktemp)"
    XDG_CONFIG_HOME="$dir" HOME="$dir" "$APP_BIN" >/dev/null 2>"$err" &
    local pid=$!
    # The config is read in init(), so anything it says is out well before the
    # panel finishes appearing.
    sleep 3
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    cat "$err"
    rm -rf "$dir" "$err"
}

expect_quiet() {
    local name="$1" json="$2"
    local out; out="$(run_with "$json")"
    local complaints; complaints="$(grep -c 'starboard config:' <<< "$out")"
    if [[ "$complaints" -eq 0 ]]; then
        pass "$name"
    else
        fail "$name" "$(grep 'starboard config:' <<< "$out" | head -3)"
    fi
}

expect_complaint() {
    local name="$1" json="$2" needle="$3"
    local out; out="$(run_with "$json")"
    if grep -q "$needle" <<< "$out"; then
        pass "$name"
    else
        fail "$name" "no '$needle' in: $(grep 'starboard config:' <<< "$out" | head -3)"
    fi
}

# ---- negative control, first ----
# Every "is silent" assertion below passes when no output is captured at all, so
# without this the suite could report success while testing nothing. Prove a
# complaint is reachable before trusting any silence.
control="$(run_with '{"fontSize": "definitely not a number"}')"
if grep -q 'starboard config:' <<< "$control"; then
    pass "the harness can see the app's warnings (negative control)"
else
    fail "negative control" "no warning captured for a knowingly broken config;
        every silence assertion below would be vacuous, so the suite stops here"
    echo
    echo "config tests FAILED"
    exit 1
fi

# ---- the quiet cases ----
expect_quiet "no config file at all is silent" ""
expect_quiet "an empty object is silent" '{}'
expect_quiet "a full valid config is silent" '{
  "fontSize": 13, "padding": 6, "cornerRadius": 10, "startExpanded": true,
  "dockTrackingInterval": 2,
  "fontNames": ["Menlo"],
  "tint": {"hex": "#101820", "alpha": 0.5},
  "material": "hudWindow",
  "fallback": {"width": 640, "height": 200, "rightMargin": 12},
  "dockCorrection": {"bottom": 4, "top": 6},
  "palette": ["#141821","#c64a5a","#4f9d69","#c49a3e","#3a7ca5","#856ea8",
              "#459c9c","#c4beac","#4b5763","#de6676","#6fbf87","#e0ba69",
              "#5fa8d3","#a98fc9","#72d6cf","#e6e0d0"]
}'
expect_quiet "component form for the tint is silent" '{"tint":{"red":0.1,"green":0.2,"blue":0.3,"alpha":0.8}}'
# JSON has no comments; the shipped example uses _-prefixed keys as a stand-in.
expect_quiet "underscore keys are comments, not unknown keys" \
    '{"_comment": "hello", "_note": ["a","b"], "fontSize": 12}'

# The shipped example must load cleanly — otherwise the first thing a user
# copies produces a screen of warnings.
expect_quiet "config.example.json loads without complaint" "$(cat "$REPO_DIR/config.example.json")"

# ---- the cases that must be reported, not swallowed ----
expect_complaint "malformed JSON is reported" \
    '{this is not json' 'not a JSON object'
expect_complaint "wrong type is reported" \
    '{"fontSize": "big"}' 'fontSize: expected a number'
expect_complaint "unknown material is reported, with the list" \
    '{"material": "velvet"}' "unknown value 'velvet'"
expect_complaint "a short palette is reported" \
    '{"palette": ["#111111","#222222"]}' 'expected exactly 16 entries'
expect_complaint "a bad palette entry is reported" \
    '{"palette": ["nope","#222222","#333333","#444444","#555555","#666666",
                  "#777777","#888888","#999999","#aaaaaa","#bbbbbb","#cccccc",
                  "#dddddd","#eeeeee","#ffffff","#101010"]}' 'not #rrggbb'
expect_complaint "an unknown key is reported" \
    '{"transparancy": 0.5}' "unknown key 'transparancy'"
expect_complaint "wrong type for a bool is reported" \
    '{"startExpanded": "yes"}' 'expected true or false'

# ---- and none of the broken ones may stop the panel ----
out="$(run_with '{"fontSize": "big", "material": "velvet", "nonsense": 1}')"
if grep -q 'starboard config:' <<< "$out"; then
    pass "a broken config still lets the panel start (warnings only, no crash)"
else
    fail "a broken config still starts" "expected warnings; got: $out"
fi

echo
if [[ "$FAILED" -eq 0 ]]; then
    echo "all config tests passed"
else
    echo "config tests FAILED"
fi
exit "$FAILED"
