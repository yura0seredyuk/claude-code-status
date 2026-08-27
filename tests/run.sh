#!/bin/bash
# The whole suite, in one command:
#
#   tests/run.sh            run it
#   tests/run.sh --update   regenerate tests/golden/state.json after a
#                           deliberate change, then read the diff before
#                           committing it
#
# Everything runs against a throwaway HOME. Nothing here touches ~/.claude.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

PY="$( [ -x /usr/bin/python3 ] && echo /usr/bin/python3 || command -v python3 )"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '    ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '    FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '%s\n' "$2"; }
is()  {
    if [ "$2" = "$3" ]; then ok "$1"
    else bad "$1" "         expected [$3]
         actual   [$2]"
    fi
}

echo "Building…"
HOOK="$WORK/hook"
swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" \
    -o "$HOOK" "$ROOT/hook/main.swift" || { echo "  hook failed to build"; exit 1; }
SWIFT_TESTS="$WORK/swift-tests"
swiftc -swift-version 5 -o "$SWIFT_TESTS" \
    "$ROOT/app/StatusIcon.swift" "$HERE/swift/main.swift" \
    || { echo "  swift assertions failed to build"; exit 1; }

# Pinned so a run is reproducible: pid 1 is always alive (kill returns EPERM)
# and the entrypoint decides the background flag. CLAUDE_CODE_SESSION_ID has to
# go — the hook falls back to it when an event carries no session_id, so running
# this from inside Claude Code would otherwise fold the caller's own session
# into the fixtures and bake its id into the golden file.
export CLAUDE_PID=1
export CLAUDE_CODE_ENTRYPOINT=cli
unset CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION CLAUDE_PROJECT_DIR

# ---------------------------------------------------------------------------
echo "Hook events -> state.json"
H1="$WORK/h1"; mkdir -p "$H1"
for f in "$HERE"/events/*.json; do
    HOME="$H1" "$HOOK" < "$f"
    status=$?
    # Every path exits 0. A non-zero exit from a hook is a disturbed session.
    [ $status -eq 0 ] || bad "$(basename "$f") exited $status"
done
ok "every event exited 0"

NORMALISE='
import json, sys
d = json.load(open(sys.argv[1]))
out = {}
for sid, r in sorted(d["sessions"].items()):
    r = dict(r)
    # Wall-clock and process identity are not behaviour.
    for k in ("started_at", "updated_at", "turn_started_at", "pid"):
        r.pop(k, None)
    if isinstance(r.get("last_error"), dict):
        r["last_error"] = {k: v for k, v in r["last_error"].items() if k != "at"}
    out[sid] = r
events = {}
for name, tally in sorted(d.get("events", {}).items()):
    events[name] = {k: v for k, v in tally.items() if k not in ("last_seen", "first_seen")}
json.dump({"sessions": out, "events": events}, sys.stdout,
          indent=2, sort_keys=True, ensure_ascii=False)
'
GOLDEN="$HERE/golden/state.json"
STATE="$H1/.claude/claude-status/state.json"
"$PY" -c "$NORMALISE" "$STATE" > "$WORK/actual.json"
if [ "$UPDATE" = "1" ]; then
    cp "$WORK/actual.json" "$GOLDEN"
    echo "    updated $GOLDEN"
elif diff -u "$GOLDEN" "$WORK/actual.json" > "$WORK/diff.txt"; then
    ok "state.json matches the golden file"
else
    bad "state.json differs from the golden file" "$(sed 's/^/         /' "$WORK/diff.txt")"
fi

# A session that ended must be gone, and an event carrying no session id must
# not invent one.
GONE=$("$PY" -c "import json;print('s3' in json.load(open('$STATE'))['sessions'])")
is "SessionEnd removed s3" "$GONE" "False"
COUNT=$("$PY" -c "import json;print(len(json.load(open('$STATE'))['sessions']))")
is "only the live sessions remain" "$COUNT" "3"

# An event this build was not written against must be counted and flagged, not
# silently dropped - that is the whole point of the tally.
UNHANDLED=$("$PY" -c "
import json
e = json.load(open('$STATE'))['events']
print(','.join(sorted(n for n, t in e.items() if t.get('unhandled'))))")
is "an unknown event is flagged" "$UNHANDLED" "ToolFailure"
TALLY=$("$PY" -c "import json;print(json.load(open('$STATE'))['events']['ToolFailure']['count'])")
is "and counted" "$TALLY" "2"
KNOWN=$("$PY" -c "
import json
e = json.load(open('$STATE'))['events']
print(sum(1 for t in e.values() if not t.get('unhandled')))")
is "handled events tallied too" "$KNOWN" "10"

# ---------------------------------------------------------------------------
echo "Status line -> limits.json"
H2="$WORK/h2"; mkdir -p "$H2"
NOW=$("$PY" -c 'import time;print(int(time.time()))')
A=$((NOW + 7200)); B=$((NOW + 400000)); EARLIER=$((A - 3600))
BOTH="5h 3% · 7d 4%"
# Captured into a variable, then compared. Nesting $(...) directly in an
# argument list mangles this path under bash 3.2, which macOS still ships.
sl() { LAST=$(echo "$1" | HOME="$H2" "$HOOK" --statusline); }

sl "{\"session_id\":\"B\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":61.0,\"resets_at\":$A}}}"
is "first reading" "$LAST" "5h 61%"

# An idle terminal re-fires the status line with its own process-cached, older
# number. Utilisation only climbs inside a window, so the lower reading loses.
sl "{\"session_id\":\"A\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":22.0,\"resets_at\":$A}}}"
is "stale lower reading loses" "$LAST" "5h 61%"

# Absence means "this process has not heard yet", never "the limit is gone".
sl '{"session_id":"C"}'
is "absence does not erase" "$LAST" "5h 61%"

sl "{\"session_id\":\"B\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":63.0,\"resets_at\":$A}}}"
is "climbing accepted" "$LAST" "5h 63%"

# A different reset time is a different window — a new generation, or another
# account after /login — so the fresh reading wins even though it is lower.
sl "{\"session_id\":\"P\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":3.0,\"resets_at\":$EARLIER},\"seven_day\":{\"used_percentage\":4.0,\"resets_at\":$B}}}"
is "account switch settles at once" "$LAST" "$BOTH"

# A NaN utilisation reaches us as JSON null.
sl "{\"session_id\":\"B\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":null,\"resets_at\":$A}}}"
is "null percentage ignored" "$LAST" "$BOTH"

sl "{\"session_id\":\"B\",\"rate_limits\":{\"seven_day\":{\"used_percentage\":90.0,\"resets_at\":$((NOW-10))}}}"
is "expired window ignored" "$LAST" "$BOTH"

sl 'not json'
is "garbage keeps the line" "$LAST" "$BOTH"

LAST=$(printf '' | HOME="$H2" "$HOOK" --statusline)
is "empty stdin keeps the line" "$LAST" "$BOTH"

# The stamp follows the reading that won: a stale session re-reporting an old
# number must not refresh an "as of" it did not earn.
"$PY" - "$H2" <<'PY'
import json, os, sys, time
p = os.path.join(sys.argv[1], ".claude/claude-status/limits.json")
d = json.load(open(p))
d["windows"]["five_hour"]["captured_at"] = time.time() - 4000
d["updated_at"] = 0
json.dump(d, open(p, "w"))
PY
sl "{\"session_id\":\"A\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":1.0,\"resets_at\":$EARLIER}}}"
AGE=$("$PY" -c "
import json, time
w = json.load(open('$H2/.claude/claude-status/limits.json'))['windows']['five_hour']
print('kept' if time.time() - w['captured_at'] > 3000 else 'refreshed')")
is "a losing sample keeps the old stamp" "$AGE" "kept"

# ---------------------------------------------------------------------------
echo "Write amplification"
BEFORE=$(stat -f %m "$H2/.claude/claude-status/limits.json")
for _ in $(seq 1 30); do
    sl "{\"session_id\":\"B\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":3.0,\"resets_at\":$EARLIER}}}"
done
AFTER=$(stat -f %m "$H2/.claude/claude-status/limits.json")
is "30 identical runs rewrite nothing" "$([ "$BEFORE" = "$AFTER" ] && echo same || echo rewritten)" "same"

# ---------------------------------------------------------------------------
echo "Concurrency and failure handling"
H3="$WORK/h3"; mkdir -p "$H3"
for i in $(seq 1 30); do
    echo "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"c$i\",\"cwd\":\"/tmp/p$i\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/a/b$i.txt\"}}" \
        | HOME="$H3" "$HOOK" &
done
wait
PARALLEL=$("$PY" -c "import json;print(len([k for k in json.load(open('$H3/.claude/claude-status/state.json'))['sessions'] if k.startswith('c')]))")
is "30 parallel hooks lose nothing" "$PARALLEL" "30"

# Nothing may be left lying around when a write cannot land.
H4="$WORK/h4"; mkdir -p "$H4/.claude/claude-status/limits.json"
for _ in 1 2 3; do
    echo "{\"session_id\":\"x\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":5.0,\"resets_at\":$A}}}" \
        | HOME="$H4" "$HOOK" --statusline >/dev/null
done
STRANDED=$(find "$H4/.claude/claude-status" -maxdepth 1 -name '*.tmp' | wc -l | tr -d ' ')
is "an unwritable limits.json strands no temp files" "$STRANDED" "0"

# ---------------------------------------------------------------------------
echo "App-side formatting and decoding"
"$SWIFT_TESTS" "$H2/.claude/claude-status/limits.json" || fail=$((fail+1))

# ---------------------------------------------------------------------------
echo
if [ "$fail" -eq 0 ]; then
    echo "PASS  ($pass shell checks, plus the Swift assertions)"
    exit 0
fi
echo "FAIL  $fail failing, $pass passing"
exit 1
