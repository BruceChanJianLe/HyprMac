# Debugging

HyprMac logs through `os.Logger` under the subsystem
`com.zachgray.HyprMac`. This document covers how to read the logs,
how to enable verbose logging in Release builds for support
sessions, and the smaller knobs available for narrowing the
output.

## Log tiers

Two tiers, defined in `Shared/Log.swift`:

- **Diagnostic** — `.notice`, `.warning`, `.error`, `.fault`.
  Always emits via `os.Logger`. Visible in Console.app for support
  even on shipping Release builds. Used for fallback / suppression
  decisions, error paths, and anything a user might be asked to
  share when reporting a bug.
- **Trace** — `.debug`, `.info`. Developer-only. In DEBUG builds,
  emits when the level is at or above `LogConfig.traceMinimum` and
  the category is in `LogConfig.enabledCategories`. In Release,
  emits only when the `HyprMacVerboseLogging` `UserDefault` is
  set.

`privacy: .public` is applied to every message because the only
metadata that enters log strings is safe (window IDs, workspace
numbers, screen names, action names, durations). Free-text user
input must not enter log strings.

## Categories

Each log site picks a category from `LogCategory`:

```
orchestration  state         focus         tiling        workspace
discovery      input         mouse         drag          hotkey
floating       ui            animator      border        dimming
overlay        config        persistence   migration     sync
lifecycle      accessibility space         display
```

Categories surface as the `category` field in Console, so you can
filter by subsystem + category to scope logs to one subsystem
without scrolling through everything.

## Console.app filter recipes

Open Console.app, set the device dropdown to your Mac, and apply
these filters via Action → Search.

### Everything HyprMac

```
subsystem:com.zachgray.HyprMac
```

### One category

Replace `tiling` with the category you want.

```
subsystem:com.zachgray.HyprMac category:tiling
```

### Errors and warnings only

```
subsystem:com.zachgray.HyprMac category:any messageType:error,fault,default
```

(`messageType:default` covers `.notice`. `messageType:info` covers
`.info`. `messageType:debug` covers `.debug`.)

Save the filter via Action → Save Search so it lands in the sidebar.

## Streaming to a file

```
log stream --predicate 'subsystem == "com.zachgray.HyprMac"' --info
```

Add `--debug` for trace logs (DEBUG builds, or Release with the
verbose toggle below). Pipe through `tee` to keep a copy:

```
log stream --predicate 'subsystem == "com.zachgray.HyprMac"' --info | tee hyprmac.log
```

Predicate variants:

```
# one category
--predicate 'subsystem == "com.zachgray.HyprMac" && category == "tiling"'

# multiple categories
--predicate 'subsystem == "com.zachgray.HyprMac" && (category == "tiling" || category == "discovery")'

# warnings and above only
--predicate 'subsystem == "com.zachgray.HyprMac"' --level warning
```

## Debug builds keep a file log

macOS never persists os_log `.debug` lines. By the time you run `log
show` after a bug, only `.notice` and above survive — every `retile:
workspace=`, `workspace N full`, `window gone:` and poll-timing line
is already gone. So debug builds also append every `hyprLog` call, at
every level and every category, to a plain text file.

Path (one file per bundle id, so the debug app and a release build
never share):

```
~/Library/Logs/HyprMac/com.zachgray.HyprMac.debug.log
```

One line per call, format stable:

```
2026-09-12T19:41:02.123-0500 [notice] [discovery] window gone: 1304
```

Timestamp, then `[level]`, then `[category]`, then the message.
Levels are `debug info notice warning error fault`; categories are the
`LogCategory` names listed above.

The file rotates at 20 MB: the current file is renamed to
`<name>.log.1` (replacing any previous `.1`) and a fresh one starts.
So the log costs at most ~40 MB on disk.

Tail it from another machine:

```bash
tail -f ~/Library/Logs/HyprMac/com.zachgray.HyprMac.debug.log
```

`WindowManager.start()` logs the exact path at `.notice`, so
`log show` tells you which file the running instance is writing to:

```bash
/usr/bin/log show --predicate 'subsystem BEGINSWITH "com.zachgray.HyprMac"' --last 5m | rg 'file log:'
```

The switch is `LogConfig.persistentFileLog` in `Shared/Log.swift`. It
defaults to `true` under `#if DEBUG`; in Release it follows the same
`HyprMacVerboseLogging` user default as trace logging (below). If the
directory or the file cannot be created the log disables itself
silently — one `.notice` says so and the app runs unchanged.

## On-demand state dump

`WindowManager.dumpState(reason:)` logs a `.notice` block under
`category: lifecycle` describing workspace, cache and tree state. It
runs once at startup right after the initial tile (`reason: startup`)
and on every `SIGUSR1`:

```bash
kill -USR1 $(pgrep -x 'HyprMac Debug')
```

Then read the file log. The block looks like:

```
state dump (SIGUSR1)
screen=Built-in Retina Display visible=ws1
screen=S34C65xT visible=ws2
ws1 home=Built-in Retina Display visible=true assigned=[104, 118] hidden=[] reserved=[] floating=[118] tree(Built-in Retina Display)=[104]
ws2 home=S34C65xT visible=true assigned=[221] hidden=[] reserved=[] floating=[] tree(S34C65xT)=[221]
scratchpad=[319]
known=4 hidden=0 reserved=0 floating=1
```

Screens first, then each workspace 1–9 that has at least one window
(empty workspaces are omitted), then the scratchpad, then cache
totals. `tree(...)` is the leaf membership of that workspace's BSP
tree on its home screen — compare it against `assigned` minus
`floating` minus `hidden` to spot a window that holds a workspace slot
but is missing from the tree. Window ids only; titles never enter the
dump.

## Verbose logging in Release

Trace-tier logs (`.debug`, `.info`) are gated off by default in
Release builds. To enable for a support session:

```
defaults write com.zachgray.HyprMac HyprMacVerboseLogging -bool YES
```

Relaunch HyprMac. The `LogConfig.verboseInRelease` getter reads the
`UserDefault` on every `hyprLog` call so the toggle takes effect on
the next emission — no further configuration needed.

To turn it back off:

```
defaults write com.zachgray.HyprMac HyprMacVerboseLogging -bool NO
```

(or `defaults delete com.zachgray.HyprMac HyprMacVerboseLogging` to
remove the key entirely.)

## DEBUG-only knobs

Two compile-time knobs in `LogConfig`, both in DEBUG builds only:

- `LogConfig.traceMinimum` — raises the trace-tier ceiling.
  Setting it to `.info` suppresses every `.debug` log;
  `.notice` would suppress every trace-tier log.
- `LogConfig.enabledCategories` — narrows trace output to a subset
  of categories. Diagnostic-tier logs always emit regardless.

Both default to "everything emits". Adjust them in `Log.swift` (or
ad hoc in `AppDelegate.applicationDidFinishLaunching`) when chasing
a noisy bug.

## Common debugging recipes

### "Why did focus end up there?"

```
subsystem:com.zachgray.HyprMac category:focus
```

Every `FocusStateController.recordFocus` call logs the
`from → to` transition with a short reason tag (`ensureFocus-tiled`,
`syncTracker-floating`, `cycleFocus`, etc.). Walk the log
backwards from the unexpected focus state to find the trigger.

### "Why didn't a swap take effect?"

```
subsystem:com.zachgray.HyprMac category:tiling
```

Watch for `swap overflow detected post-readback — reverting` (the
seeded min lied) or `swap would violate min-size constraints`
(rejected up front by `canSwapWindows`).

### "Why is dimming wrong?"

```
subsystem:com.zachgray.HyprMac (category:dimming || category:focus || category:lifecycle)
```

The dim mask reacts to focus changes; mismatches usually trace back
to `WindowStateCache.tiledPositions` going stale between
poll/retile cycles. `WindowManager.currentTiledRects` re-reads live
AX before `refreshDimming` and `refreshBorderOcclusion` to avoid
the "half-dim" artifact — if you see stale-rect dimming, that read
path is the place to look first.

### "Why did discovery think this was a new window?"

```
subsystem:com.zachgray.HyprMac category:discovery
```

`window returned`, `new window`, `window hidden`, and `window
gone` log every transition. `WindowStateCache.knownWindowIDs`
tracks the "seen since launch" set; a window appearing as `new`
when the user un-hides it usually means it was forgotten too
aggressively (e.g. on app terminate before the visibility change
flowed through).

Two trace lines measure the gap between "the OS told us" and "we
looked", which only the file log keeps:

- `ax event: windowDestroyed pid=1304` — one per AX notification, kind
  and pid only.
- `poll: 14 windows, 213ms since last` — at the top of every
  `pollWindowChanges`, with the snapshot size and the elapsed wall
  clock since the previous poll.

## Retile churn / full-screen flicker

Symptom: two tiled windows, one keeps snapping full-screen and back
every ~1 s while the other stays put; dimming redraws with each snap.
Mechanism: an app whose main thread stalls fails its AX reads for a
poll cycle, all its windows drop from that `getAllWindows` snapshot,
discovery marks them gone→hidden, the sibling's node is promoted and
retiled to the full rect; the next healthy cycle returns them and
retiles back. Notice-tier evidence chain (all `category: discovery`):

- `AX window-list read FAILED for <bundle>` / `recovered after N
  failed cycle(s)` — the root cause, logged on outage edges only.
- `AX frame read FAILED for N window(s) of <bundle>` — per-window
  variant of the same failure.
- `window hidden: <id> (<bundle>)` / `window returned` — the
  discovery transitions.
- `FLAP: '<title>' returned <ms>ms after vanishing` — a return within
  5 s of vanishing, i.e. almost certainly not a real minimize.
- `discovery retile: gone=[...] returned=[...]` — one line per
  discovery-driven re-layout naming its cause.

Pull with:

```bash
/usr/bin/log show --predicate 'subsystem == "com.zachgray.HyprMac" AND category == "discovery"' --last 10m --info
```

## Where the logs come from

- `WindowManager` lifecycle — `category: lifecycle`.
- Action dispatch and routing — `category: orchestration`.
- Focus transitions — `category: focus`.
- Tile mutations and swap decisions — `category: tiling`.
- Workspace switches and moves — `category: workspace`.
- Discovery diff results — `category: discovery`.
- Drag classification — `category: drag`.
- Floating window operations — `category: floating`.
- Suppression registry decisions — `category: state`.
- Config load/save — `category: config`.

`grep -rn 'hyprLog(.notice\|hyprLog(.warning\|hyprLog(.error\|hyprLog(.fault' HyprMac/`
gives a complete index of diagnostic-tier sites.
