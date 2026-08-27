# App Store listing

The copy that goes into App Store Connect, kept here so it is versioned and
checkable rather than living in a browser tab.

Apple indexes the **app name, the subtitle and the keyword field, and nothing
else** — the description is not searched, not one word of it. That is 160
characters of search surface in total.

## Metadata

| Field | Limit | Used | Value |
|---|---|---|---|
| App name | 30 | 10 | `Statuslamp` |
| Subtitle | 30 | 22 | `Status for Claude Code` |
| Keywords | 100 | 81 | `agent,terminal,cli,menu bar,usage,limit,monitor,hook,coding,session,indicator,mac` |

No keyword repeats a word already in the name or subtitle; a duplicate is
spent characters buying nothing. Commas, no space after them.

Subtitles considered, with counts:

- `Status for Claude Code` — 22
- `What Claude Code is doing` — 25
- `Claude Code status and limits` — 29
- `Menu bar status for Claude Code` — 31, one over, which is why "menu bar"
  lives in the keyword field instead

Other fields:

- **Category** — Developer Tools (`LSApplicationCategoryType` in the bundle
  already matches: `public.app-category.developer-tools`)
- **Privacy** — no data collected. Nothing leaves the machine; the app reads
  local files written by Claude Code and makes no network request of any kind.
- **Copyright** — matches `NSHumanReadableCopyright` in `Info.plist`
- **Support URL** — required; the repository will do

## Screenshots

```bash
swiftc -swift-version 5 app/StatusIcon.swift tools/store-shots/main.swift -o /tmp/shots
/tmp/shots store/screenshots
```

Three, at 2880×1800. Connect wants 16:10 between 1280×800 and 2880×1800,
flattened RGB with **no alpha channel** — a crop of the menu is none of those,
which is why they are composed rather than screen-grabbed. The menu itself is
captured from the shipping drawing code and drawn at the pixel size it really
is, so the picture is not flattering the app.

The PNGs are build output and are not tracked; one command remakes them.

## Before any of this can be submitted

Three things are unresolved, and two of them are structural:

1. **The app may not install its own hook.** Guideline 2.5.2 forbids writing
   outside the container or installing code that changes another app's
   functionality; registering the hook in `~/.claude/settings.json` is exactly
   that. A store build would have to walk the user through doing it by hand.
2. **The sandbox cannot read `~/.claude`.** No entitlement grants a fixed path
   outside the container. The temporary-exception entitlements still work
   technically, but Apple's own developer support says App Review typically
   rejects them. The ways out are a folder picker on first run, or routing the
   state through an App Group container the app owns.
3. **On a clean review machine it does nothing.** Guideline 4.2.3(i): an app
   should work without requiring another app. With no Claude Code installed
   this is a grey circle and an empty menu — a 2.1 "unable to review" as much
   as a 4.2. A demo mode with synthetic sessions answers it and needs no file
   access at all.

Also worth knowing before spending the effort: six comparable apps are already
in this category collecting these searches, and among eligible apps Apple ranks
by downloads, conversion, reviews and retention — all of which start at zero.

## Submitting, when the time comes

1. Enrol in the Apple Developer Program ($99/year) and create a Developer ID
   plus an App Store distribution certificate.
2. In App Store Connect, create the app record: bundle id
   `io.github.yura0seredyuk.statuslamp`, the name and subtitle above.
3. Fill the privacy questionnaire — "no data collected" throughout.
4. Upload the screenshots from `store/screenshots/`.
5. Build for the store, which is a different build from `release.sh`: it needs
   the App Sandbox entitlement and the store certificate, and it must have the
   three blockers above resolved first.
6. Submit, and expect a round of rejection on 4.2.3(i).

`release.sh` produces the **outside-the-store** build: notarised, unsandboxed,
and unaffected by any of the above.
