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
error. Clicking a session opens its folder in Finder. It also shows how much of
your plan's 5-hour and weekly limits you have spent.

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

## Plan usage limits

The menu carries two rows for the account's usage windows:

```
▬▬▬▬▬▬░░  Session limit (5h)   87%  ·  resets in 1h 15m
▬░░░░░░░  Weekly limit (7d)     9%  ·  resets in 3d 9h
```

The bar goes orange past 80% and red past 95%, and crossing either threshold
alerts once per window — "Session limit (5h) — 87% used". **Limit alerts** and
**Show usage in menu bar** (a percentage beside the icon) are switches in the
menu; the second one is off by default.

Per-model weekly windows appear underneath when there are any:

```
▬▬▬░░░░░  Fable (7d)          38%  ·  resets in 2d 7h  ·  as of 12m ago
```

These come from somewhere else, and the row says so by always carrying its age.
The status line publishes only the two account-wide windows; per-model ones live
in the `/api/oauth/usage` response, which Claude Code caches into
`~/.claude.json` as `cachedUsageUtilization` **every time you open `/usage`** —
and nowhere else. So the app reads that file (free, no credentials) rather than
calling the endpoint itself, and the number is only as fresh as your last
`/usage`. Past 24 hours the row is dropped rather than shown at whatever it said
yesterday.

A model you have not used has no window: the server sends it as 0% with a null
reset time, and a bar that sits at zero forever is worse than no row, so nothing
is drawn until the window actually opens.

### What it costs, and how to decline

Claude Code publishes these numbers in exactly one local place: the JSON it
hands to the `statusLine` command. No hook event carries a usage field, there is
no `claude usage` subcommand, no environment variable and no OTel metric.

And `settings.json` has room for exactly one `statusLine` — it is a scalar, not
a merged list like `hooks` — so this takes the bottom line of your terminal,
where it prints `5h 87% · 7d 9%`. If you would rather keep that line for
something else:

```bash
./install.sh --no-limits
```

That leaves the icon and the session rows exactly as they are and hands the slot
back. Worth knowing before you decide: on an API-key, Bedrock or Vertex account
the numbers never arrive at all (see below), so there the slot buys you nothing.

If the slot is **already taken** by your own status line, the installer refuses
to touch it — that is not a preference, it is not destroying a config you wrote —
and prints what to add at the top of your own script instead. Read stdin once,
then fan it out:

```sh
input=$(cat)
printf '%s' "$input" | /usr/bin/python3 "$HOME/.claude/claude-status/hook.py" --statusline >/dev/null 2>&1
printf '%s' "$input" | <the rest of your status line>
```

Claude Status never wraps or rewrites a status line it did not write. Chaining
would put a Python start in front of yours on every redraw, swallow your script's
exit code, and leave a restore path that a failed uninstall could strand.

### What the numbers can and cannot tell you

The status line runs **only while an interactive Claude Code terminal is on
screen** — never for `claude -p`, the SDK or MCP. So a batch job can spend quota
all afternoon without moving the bar, and with every terminal closed the number
simply stands still. Any reading older than ten minutes therefore carries an
"as of 4h ago" marker, and a window is dropped once its `resets_at` passes
rather than shown at its pre-reset value.

Each Claude Code process keeps its own copy of the figures, fed only by its own
API responses, so shift-tabbing in a terminal that has been idle since morning
re-fires its status line with this morning's number. Utilisation only climbs
until a window resets, so within one window `limits.json` keeps the highest
reading and discards anything lower as an older session's view — while a
*different* reset time means a different window, or a different account after
`/login`, and always wins. A window missing from a payload means "this process
has not heard yet", never "the limit is gone" — a fresh terminal always reports
one that way before its first API response — so absence never erases what is
already known.

Nothing in the payload identifies the account, so on a machine used with two of
them the rows follow whichever one Claude Code talked to last.

When there is nothing to show the row says which kind of nothing it is: *no
reading yet* (Claude Code publishes these only after an API response, and never
for API-key, Bedrock or Vertex sessions), *window reset*, *no Claude Code
session running*, or *not updating* — the last one meaning something replaced
the `statusLine` entry, which Claude Code's own `/statusline` command will do.

Not done, deliberately: polling Anthropic's `/api/oauth/usage` directly. It
needs the full `/login` credential from the keychain, and refreshing that token
independently rotates it out from under Claude Code, whose `invalid_grant`
handler then wipes the stored credential and demands a fresh `/login`. A status
widget must not be able to log you out.

## Install

```bash
./install.sh
```

Builds the app, puts it in `/Applications`, copies the hook into
`~/.claude/claude-status/` and adds the hooks to `~/.claude/settings.json`
(backing it up first), plus the `statusLine` that feeds the plan usage rows.
Re-running is safe — it never duplicates entries.

**Hooks are read when a session starts**, so restart any Claude Code terminals
that are already open before they start reporting.

"Open at login" is a checkbox in the icon's menu, backed by `SMAppService`
(macOS 13+). Earlier versions wrote `~/Library/LaunchAgents/…plist` by hand;
that plist is migrated and deleted on first launch, because with both in place
macOS starts the app twice. The switch can also read "approve in System
Settings" — a login item the user has turned off there is a state a plist on
disk cannot represent, so the old code showed a tick for something that was
never going to fire.

## Uninstall

```bash
./uninstall.sh
```

Strips the hooks out of `settings.json` (leaving anyone else's hooks alone, and
the `statusLine` too unless it is ours), removes the launch agent, the app and
`~/.claude/claude-status/`.

## How it works

Claude Code can run external commands on session events. The hook
(`hook/main.swift`, compiled into the app bundle and copied to
`~/.claude/claude-status/hook` at install time) receives each event as JSON on
stdin, folds it into a single state file at
`~/.claude/claude-status/state.json`, and the app re-reads that file twice a
second and draws the icon.

It is copied out of the bundle rather than run from inside it so that the
registered hook keeps working while the app is quit, moved or updated.

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

Plan usage limits arrive by a different route - the `statusLine` command, which
the same script serves with `--statusline`, writing `limits.json` beside
`state.json`.

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

And about the status line, which is where the plan limits live:

- `rate_limits` carries `five_hour` and `seven_day` only, each
  `{used_percentage, resets_at}` with `resets_at` in unix epoch **seconds**. The
  richer shape — `seven_day_opus`, `seven_day_sonnet`, `model_scoped`,
  `extra_usage`, ISO timestamps — belongs to the SDK's experimental `get_usage`
  control request and never appears here. The header table the status line is
  built from has four entries (`5h`, `7d`, `7d_oi`, `overage`) and none of them
  is per-model.
- The same richer payload is cached to `~/.claude.json` under
  `cachedUsageUtilization` — written at most once every 5 minutes, only when
  `/usage` or an SDK `get_usage` runs, and treated as expired after an hour.
  Its `resets_at` is an ISO 8601 string with **microseconds**, which
  `ISO8601DateFormatter` rejects with or without `.withFractionalSeconds`;
  dropping the fraction parses every shape the server sends.
- The figures come from `anthropic-ratelimit-unified-*` response headers and are
  cached per process, not on disk: absent until that process's first API
  response, and absent forever for API-key, Bedrock and Vertex sessions.
- A window disappears from the payload the moment its `resets_at` passes, and
  Claude Code re-runs the status line one second later, so a rollover refreshes
  even in an idle terminal.
- The command re-runs on a 300 ms debounce whenever token usage, permission
  mode, vim mode, model, fast mode, effort, thinking or PR status changes, and on
  every new assistant message — several times a second during a streaming turn.
  So the writer only rewrites `limits.json` when a number actually moved.
- It has no `timeout` field of its own; it inherits the generic 10-minute hook
  timeout. A non-zero exit makes Claude Code discard stdout and blank the row, so
  `--statusline` exits 0 on every path, exactly like the hook.
- Empty stdout does not fall back to a default status line — there isn't one.

### Why it cannot disturb Claude Code

- The hook writes nothing to stdout — `UserPromptSubmit` stdout is injected into
  the model's context.
- The command in `settings.json` ends with `>/dev/null 2>&1 || true`, so even a
  broken hook cannot fail a tool call.
- Concurrent writes are serialised with `flock` and the file is replaced
  atomically. Measured: 30 parallel hooks, 30 records, nothing lost.
- Overhead is roughly 8 ms per tool call. It was 29 ms while the hook was a
  Python script — nearly all of it interpreter start, which is why it is compiled
  now.
- `JSONSerialization` rejects the raw newlines Claude Code puts inside string
  values, and unlike Python's `json` it has no `strict=False`. The hook escapes
  control characters inside string literals itself before parsing.

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
hook/main.swift             events → state.json, --statusline → limits.json
hook/install-hooks.py       edits ~/.claude/settings.json (hooks + statusLine)
tools/make-icon/            draws the app icon and writes the .iconset
tools/render-icons/         dumps every menu bar icon state to a PNG sheet
tools/menu-text/            prints the menu as text
tools/demo-state.py         injects fake sessions for eyeballing
```

`build.sh` produces a universal (arm64 + x86_64) bundle with the hardened
runtime on and an ad-hoc signature. For a release, point it at a real identity —
nothing else changes, and the result is notarizable as-is:

```bash
SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" VERSION=1.1 ./app/build.sh
```

`CFBundleVersion` comes from `git rev-list --count HEAD`, so it moves on its own.

Iterating without a full reinstall:

```bash
./app/build.sh && open "app/build/Claude Status.app"   # app only
swiftc -swift-version 5 app/StatusIcon.swift tools/render-icons/main.swift \
    -o /tmp/render && /tmp/render                       # icon preview
/usr/bin/python3 tools/demo-state.py --limits           # fake sessions + limits
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

macOS 13+ to run. Building from this repo additionally needs the Xcode Command
Line Tools (for `swiftc`) and `/usr/bin/python3` (the installer script only —
nothing Python remains on the runtime path).

The build is a universal binary with the hardened runtime on, ad-hoc signed;
set `SIGN_IDENTITY` to a Developer ID and it comes out notarizable unchanged.
