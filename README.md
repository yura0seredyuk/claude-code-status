# Claude Status

A macOS menu bar icon that shows what Claude Code is doing in your terminal.

```
◜◝  Working          blue ring, spinning
⏸   Waiting for you  orange — needs a permission or an answer
✓   Done             green — Claude finished its turn
!   Error            red — an API failure, or the turn ended on a failed tool
○   No sessions      grey outline
```

With several sessions running, the icon shows the most important state
(error → waiting → working → done) and the session count beside it.
A red dot on the blue ring means something failed during the current turn
but Claude is still working.

Clicking the icon lists the sessions: project, what is running right now, how
long the turn has taken, how many tool calls it made and the text of the last
error. Clicking a session opens its folder in Finder.

## Alerts

A session changing to **waiting**, **error** or **done** plays a sound (Funk,
Basso, Glass) and posts a notification naming the project and the reason —
"berig — Done · “All tests pass”". Both are separate switches in the menu, and
**Test alert** fires one on demand so you can check they work without waiting
for Claude.

Alerts are per session, not per icon: two projects both asking for permission
are two things you need to know about. A session is only alerted on when it
*changes*, so nothing fires for whatever was already on screen when the app
started.

macOS asks for notification permission the first time the app runs. If you
dismissed that prompt, switch it back on in System Settings → Notifications →
Claude Status.

## Install

```bash
./install.sh
```

Builds the app, puts it in `/Applications`, copies the hook into
`~/.claude/claude-status/` and adds the hooks to `~/.claude/settings.json`
(backing it up first). Re-running is safe — it never duplicates entries.

**Hooks are read when a session starts**, so restart any Claude Code terminals
that are already open before they start reporting.

"Open at login" is a checkbox in the icon's menu. It only creates (or removes)
`~/Library/LaunchAgents/com.claudestatus.agent.plist` — launchd picks it up at
your next login. Deliberately no `launchctl bootstrap`: that would start a
second copy of the app right now, and the matching `bootout` on disable would
kill the very instance whose menu you are clicking in.

## Uninstall

```bash
./uninstall.sh
```

Strips the hooks out of `settings.json` (leaving anyone else's hooks alone),
removes the launch agent, the app and `~/.claude/claude-status/`.

## How it works

Claude Code can run external commands on session events. The hook
`hook/claude-status-hook.py` receives each event as JSON on stdin, folds it into
a single state file at `~/.claude/claude-status/state.json`, and the app re-reads
that file twice a second and draws the icon.

Event → state mapping:

| Claude Code event    | State                                                     |
|----------------------|-----------------------------------------------------------|
| `SessionStart`       | session appears in the list; `source="compact"` deliberately changes nothing — auto-compaction happens **mid-turn** |
| `UserPromptSubmit`   | **working** — turn begins, counters reset                  |
| `PreToolUse`         | **working** — shows the tool name and its argument         |
| `PostToolUse`        | **working** — the tool succeeded                           |
| `PostToolUseFailure` | a tool failed → red badge dot                              |
| `PermissionRequest`  | **waiting for you** — permission prompt is up              |
| `PermissionDenied`   | you declined → back to **working**                         |
| `Notification`       | **waiting for you**, depending on the notification type    |
| `Stop`               | **done**, or **error** if the last tool calls were failing  |
| `StopFailure`        | **error** — API failure: rate limit, overload, auth         |
| `SessionEnd`         | session drops off the list                                 |

The icon turns red in two cases: the turn died on an API failure (`StopFailure`,
which shows the reason in words, e.g. "Rate limit"), or the turn ended while the
most recent tool calls were failing. A single failed call that Claude recovered
from only shows a red badge dot and does not colour the icon — otherwise the
menu bar would flash red every time a `grep` found nothing.

### What testing revealed about hooks

Established empirically on Claude Code 2.1.223 by running sessions with a
logging hook; none of this is in the public documentation:

- **`PostToolUse` fires only on success.** A failed call does not trigger it at
  all. Failures get their own event, **`PostToolUseFailure`**, carrying
  `error`, `is_interrupt`, `tool_use_id` and `duration_ms`.
- **`is_interrupt: true`** means the user pressed Esc rather than something
  breaking, so that case does not colour the icon red.
- **`PermissionRequest`** is a separate event fired before the permission
  prompt. `permissionDecision` applies only to `PreToolUse`, so a silent hook
  that exits 0 decides nothing on your behalf.
- **stdin JSON can contain raw newlines inside string values** (e.g.
  `"error": "Exit code 9\noops"`), which strict JSON forbids. The hook parses
  with `strict=False` — without it, it crashes.
- Hooks get the environment variables `CLAUDE_PID` (the Claude Code process id),
  `CLAUDE_PROJECT_DIR`, and `CLAUDE_CODE_CHILD_SESSION=1` for subagent sessions.
- Beyond the documented events there are `StopFailure` (API failure, with
  `error` and `error_details`), `PermissionDenied`, `PostToolBatch`,
  `SubagentStart`, `Elicitation` and `UserPromptExpansion`. `Notification` has
  matcher subtypes: `permission_prompt`, `idle_prompt`, `agent_needs_input`,
  `elicitation_dialog`.
- `SessionStart.source` is one of `startup`, `resume`, `clear`, `compact`,
  `fork` — and `compact` arrives in the middle of a running turn.
- `--settings <file>` **replaces** the global `hooks` block rather than merging
  into it.

### Why it cannot disturb Claude Code

- The hook writes nothing to stdout — `UserPromptSubmit` stdout is injected into
  the model's context.
- The command in `settings.json` ends with `>/dev/null 2>&1 || true`, so even a
  broken hook cannot fail a tool call.
- Concurrent writes are serialised with `flock` and the file is replaced
  atomically. Measured: 20 parallel hooks, 20 records, nothing lost.
- Overhead is roughly 28 ms per tool call.

### Known limitation

Claude Code sends `PermissionRequest` before the permission prompt, but sends
**nothing when you click "allow"** — no such event exists in the hook API. So
after you approve, the session stays orange until the tool call finishes, which
is noticeable on a long build. It corrects itself as soon as the tool returns.
This is deliberate: showing "waiting" for slightly too long is safer than
guessing with a timeout and missing a genuine long wait while you are away from
the keyboard.

### Clearing dead sessions

Each session record stores the Claude Code process `pid`. The app checks it with
`kill(pid, 0)` **on every poll**, not only when the file changes: a dead session
stops writing, so otherwise it would drive the icon forever — an orange
"waiting for you" for a terminal that is already closed. The hook additionally
drops records older than a day.

### Which sessions count as background

Hidden-by-default sessions are decided by `CLAUDE_CODE_ENTRYPOINT`: `sdk-cli`,
`sdk-py`, `sdk-ts` and `mcp` are non-interactive callers — a `claude -p` spawned
by a workflow, say — while `cli`, `vscode` and `jetbrains` are you at a keyboard.

The obvious-looking signal, `CLAUDE_CODE_CHILD_SESSION=1`, is wrong for this:
some setups run your own terminal under an agent harness that sets it, so using
it hides the very sessions the indicator exists for — silently, because a hidden
session never reaches the icon and never fires an alert. Subagents need no
special handling at all: they report under their parent's `session_id`, so they
update the existing record instead of adding one.

"Show background sessions" in the menu reveals the hidden ones.

## Layout

```
app/StatusIcon.swift        states, icon drawing, menu text
app/main.swift              menu, state reading, open at login
app/build.sh                builds Claude Status.app (no Xcode project)
app/AppIcon.icns            generated app icon, regenerated when stale
hook/claude-status-hook.py  events → state.json
hook/install-hooks.py       edits ~/.claude/settings.json
tools/make-icon/            draws the app icon and writes the .iconset
tools/render-icons/         dumps every menu bar icon state to a PNG sheet
tools/menu-text/            prints the menu as text
tools/demo-state.py         injects fake sessions for eyeballing
```

Iterating without a full reinstall:

```bash
./app/build.sh && open "app/build/Claude Status.app"   # app only
swiftc -swift-version 5 app/StatusIcon.swift tools/render-icons/main.swift \
    -o /tmp/render && /tmp/render                       # icon preview
/usr/bin/python3 tools/demo-state.py                    # fake sessions
/usr/bin/python3 tools/demo-state.py --clear

swiftc -swift-version 5 tools/make-icon/main.swift -o /tmp/mk \
    && /tmp/mk preview /tmp/icons.png                   # compare icon variants
```

The app icon is four arcs in the four state colours on a dark plate, drawn at
each target size rather than downscaled from 1024 so the strokes stay crisp;
below 32pt the strokes and gaps widen so the segments do not smear together.
`build.sh` regenerates `app/AppIcon.icns` whenever the generator is newer.

Hook diagnostics: `CLAUDE_STATUS_DEBUG=1` writes a log to
`~/.claude/claude-status/hook.log`.

## Requirements

macOS 13+, Xcode Command Line Tools (for `swiftc`), `/usr/bin/python3`.
The app is ad-hoc signed and runs locally; notarisation is not needed.
