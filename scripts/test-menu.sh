#!/usr/bin/env bash
# Checks the right-click menu and the tint colour picker.
#
# Neither can be driven by clicking from a script, so the app carries two hidden
# self-check modes that run the *same* code the UI runs:
#
#   --dump-menu              builds the real menu, injects what AppKit appends,
#                            runs the real strip, prints what survives
#   --save-tint <hex> <a>    calls the real StarboardConfig.saveTint
#
# Neither opens a panel, so this suite needs no GUI session.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; FAILED=1; }

# Rebuild and test the fresh binary, not the copy install.sh left in the bundle.
if command -v swift >/dev/null 2>&1; then
    (cd "$REPO_DIR" && swift build -c release >/dev/null 2>&1) \
        || echo "  note  swift build failed; testing the existing binary"
fi
BIN="$REPO_DIR/.build/release/Starboard"

echo "--- menu and colour picker tests ---"

if [[ ! -x "$BIN" ]]; then
    echo "  SKIP  not built (swift build -c release)"
    exit 0
fi

# ---------------- the menu ----------------
OUT="$("$BIN" --dump-menu 2>/dev/null)"

ours="$(grep -oE '^OURS [0-9]+' <<< "$OUT" | awk '{print $2}')"
injected="$(grep -oE '^AFTER-INJECTION [0-9]+' <<< "$OUT" | awk '{print $2}')"
stripped="$(grep -oE '^AFTER-STRIP [0-9]+' <<< "$OUT" | awk '{print $2}')"

# Negative control: if the injection did not actually add anything, the strip
# below proves nothing at all.
if [[ -n "$injected" && -n "$ours" && "$injected" -gt "$ours" ]]; then
    pass "the harness really injects foreign items ($ours → $injected)"
else
    fail "negative control" "injection added nothing ($ours → ${injected:-?}); the strip check would be vacuous"
    echo; echo "menu tests FAILED"; exit 1
fi

if [[ "$stripped" == "$ours" ]]; then
    pass "the strip removes exactly the foreign items ($injected → $stripped)"
else
    fail "strip count" "expected $ours after stripping, got ${stripped:-?}"
fi

for want in "Copy" "Paste" "Select All" "Toggle Expanded" "Tint Colour…" "Reveal Config in Finder" "Quit Starboard"; do
    grep -qxF "ITEM $want" <<< "$OUT" && pass "kept: $want" || fail "missing: $want"
done
for unwanted in "AutoFill" "Services" "Spelling and Grammar" "Substitutions"; do
    grep -qxF "ITEM $unwanted" <<< "$OUT" && fail "still present: $unwanted" || pass "removed: $unwanted"
done
# Our own separators must survive — they carry the tag too.
if [[ "$(grep -cxF 'ITEM ---' <<< "$OUT")" -eq 2 ]]; then
    pass "both separators survive the strip"
else
    fail "separators" "expected 2, got $(grep -cxF 'ITEM ---' <<< "$OUT")"
fi

# ---------------- the colour picker's write path ----------------
# The colour is the least interesting part; what matters is that writing it does
# not eat the rest of the file.
TMP="$(mktemp -d)"
mkdir -p "$TMP/starboard"
cat > "$TMP/starboard/config.json" <<'EOF'
{
  "_comment": "must survive",
  "fontSize": 13,
  "material": "hudWindow",
  "startExpanded": true,
  "palette": ["#141821","#c64a5a","#4f9d69","#c49a3e","#3a7ca5","#856ea8",
              "#459c9c","#c4beac","#4b5763","#de6676","#6fbf87","#e0ba69",
              "#5fa8d3","#a98fc9","#72d6cf","#e6e0d0"],
  "tint": {"hex": "#000000", "alpha": 0.1}
}
EOF

if XDG_CONFIG_HOME="$TMP" "$BIN" --save-tint "#1a2b3c" 0.42 >/dev/null 2>&1; then
    pass "saveTint reports success"
else
    fail "saveTint failed"
fi

python3 - "$TMP/starboard/config.json" <<'PY' && pass "the rest of the config survives a tint write" || fail "config damaged by the tint write"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["tint"]["hex"] == "#1a2b3c", d["tint"]
assert abs(d["tint"]["alpha"] - 0.42) < 1e-6, d["tint"]
assert d["fontSize"] == 13
assert d["material"] == "hudWindow"
assert d["startExpanded"] is True
assert len(d["palette"]) == 16
assert d["_comment"] == "must survive"
PY

# Writing into a directory that does not exist yet must work: someone who never
# copied the example still gets a file when they pick a colour.
FRESH="$(mktemp -d)"
if XDG_CONFIG_HOME="$FRESH" "$BIN" --save-tint "#ffffff" 1.0 >/dev/null 2>&1 \
   && [[ -f "$FRESH/starboard/config.json" ]]; then
    pass "a missing config directory is created"
else
    fail "missing directory" "no file at $FRESH/starboard/config.json"
fi

# And the file it produced must load without complaint. Needs a GUI session,
# since this actually starts the panel.
if launchctl print gui/"$(id -u)" >/dev/null 2>&1; then
    set +m
    ERRFILE="$(mktemp)"
    XDG_CONFIG_HOME="$TMP" HOME="$TMP" "$BIN" >/dev/null 2>"$ERRFILE" &
    APP_PID=$!
    sleep 3
    kill "$APP_PID" 2>/dev/null
    wait "$APP_PID" 2>/dev/null
    # The trust line proves the app got far enough to read the config at all —
    # without it, "no warnings" would just mean "nothing ran".
    if ! grep -q 'accessibility trusted' "$ERRFILE"; then
        fail "the app started for the load check" "no output in $ERRFILE"
    elif grep -q 'starboard config:' "$ERRFILE"; then
        fail "the written config loads cleanly" "$(grep 'starboard config:' "$ERRFILE" | head -3)"
    else
        pass "the written config loads without a single warning"
    fi
    rm -f "$ERRFILE"
else
    echo "  SKIP  no GUI session; cannot start the panel for the load check"
fi

rm -rf "$TMP" "$FRESH"

echo
if [[ "$FAILED" -eq 0 ]]; then
    echo "all menu and colour picker tests passed"
else
    echo "menu and colour picker tests FAILED"
fi
exit "$FAILED"
