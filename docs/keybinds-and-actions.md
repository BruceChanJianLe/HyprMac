# Keybinds and actions

Keybinds map a key chord to an `Action`. The `Action` enum is the
protocol between `HotkeyManager` (which produces values) and
`ActionDispatcher` (which applies them). This document is the
reference for the wire format and the schema-stability contract.

## Action enum

```swift
enum Action: Equatable {
    case focusDirection(Direction)
    case swapDirection(Direction)
    case switchWorkspace(Int)
    case moveToWorkspace(Int)
    case moveWindowToMonitor(Direction)
    case toggleFloating
    case toggleSplit
    case showKeybinds
    case showWorkspaceOverview
    case launchApp(bundleID: String)
    case focusMenuBar
    case focusFloating
    case moveToNextEmptyWorkspace
    case closeWindow
    case cycleWorkspace(Int)
    case resizeDirection(Direction)
    case toggleScratchpad
    case moveToScratchpad
    case toggleTiling
    case applyWindowRules
    case runCommand(label: String, command: String)
}
```

`Direction` is `enum Direction: String, Codable { left, right, up, down }`.

`cycleWorkspace(Int)` takes `+1` (next occupied workspace on the
current monitor) or `-1` (previous). `moveWindowToMonitor` honors all
four directions: it moves the focused window to the visible workspace of
the nearest enabled monitor that lies wholly in that direction, left and
right for side-by-side arrangements, up and down for stacked ones. The
pick is `WorkspaceOrchestrator.nearestScreenIndex`, a pure function over
`NSScreen.frame` rectangles: nearest along the axis wins, a tie goes to
the monitor sharing the most extent with the source on the cross axis.
Nothing that way beeps and flashes. Defaults are Hypr+Ctrl+arrow. The
case was repurposed from the old workspace-to-monitor move, which static
anchoring made a permanent no-op; its wire key is unchanged (see below).

## Dedicated workspace and workspace 10

`moveToNextEmptyWorkspace` defaults to Hypr+F and encodes as
`{"moveToNextEmptyWorkspace":{}}`. `focusFloating` keeps its wire key and
now defaults to Hypr+Shift+T. The new action is unavailable while paused and
ignores keyboard autorepeat. It selects the actual AX-focused managed window,
not the cursor's monitor, and moves it to the next empty workspace anchored to
its physical display. See the README for eligibility and rejection behavior.

`applyWindowRules` defaults to Hypr+Shift+R and encodes as
`{"applyWindowRules":{}}`. It moves every open window of a pinned app onto
its rule's workspace (see "Window rules" below), is unavailable while
paused, and ignores keyboard autorepeat.

Regular workspace IDs are 1–10. The physical 0 key maps to ID 10:
Hypr+0 switches, and Hypr+Shift+0 sends. Their wire values remain
`{"switchDesktop":{"_0":10}}` and `{"moveToDesktop":{"_0":10}}`.
Internal workspace 0 still means scratchpad. No workspace renumbering or schema
migration is involved.

`mergeNewDefaults` first runs the legacy Shift+T Toggle Float migration, then
the narrow F-to-Shift+T Cycle Floating migration. The latter requires one exact
old default, an unambiguous F chord, a free Shift+T chord, and no saved dedicated
workspace action. Default injection then fills free chords for missing actions.
Custom and conflicting bindings survive unchanged. Startup/reload migration is
idempotent and is persisted on the next normal settings save; no schema-version
flag is added. An explicitly chosen binding identical to a legacy default cannot
be distinguished from that default.

## JSON wire format

The `Codable` implementation in `Models/Action.swift` preserves the
v0.4.2 synthesized format byte-for-byte. Each case encodes as a
single-key object with the case name as the key and the payload as
the value:

```json
{ "switchDesktop": { "_0": 3 } }
{ "focusDirection": { "_0": "left" } }
{ "launchApp": { "bundleID": "com.apple.Terminal" } }
{ "runCommand": { "label": "Screenshot", "command": "/usr/sbin/screencapture -i ~/Desktop/shot.png" } }
{ "toggleFloating": {} }
```

Cases without payloads still encode as `{ "case_name": {} }` —
nested empty containers, matching the synthesized format Swift
produces for cases with no associated values.

## Frozen case keys

The JSON case keys are an API guarantee. The `switchWorkspace` /
`moveToWorkspace` / `moveWindowToMonitor` cases were renamed in code
(formerly `switchDesktop` / `moveToDesktop` /
`moveWorkspaceToMonitor`); the JSON wire format keeps the legacy
names indefinitely:

```swift
private enum CaseKey: String, CodingKey {
    case switchWorkspace     = "switchDesktop"
    case moveToWorkspace     = "moveToDesktop"
    case moveWindowToMonitor = "moveWorkspaceToMonitor"
    // ...
}
```

The decoder also accepts the new names as aliases, so a hand-edited
config using `switchWorkspace` or `moveWindowToMonitor` decodes
cleanly. The encoder always writes the canonical (legacy) name. End
result: existing user configs never see noisy churn after an
in-code rename — and existing `Hypr+Ctrl+arrow` binds picked up the
new move-window semantics with no config change.

This pattern generalizes — any future case rename should add an
alias entry rather than break the wire format.

## `AnyKey`

`Action.swift` declares a small file-private `AnyKey: CodingKey`
type that lets the decoder read the outer case-name key without
pre-declaring every accepted alias as a `CodingKey` case. It is
five lines and earns its keep by enabling the alias-map lookup. If
a similar dynamic-key reader appears elsewhere, it can move to
`Shared/`.

## Decoder tolerance

Malformed payloads are handled defensively rather than crashing.

- **Direction**: `Action.decodeDirection` accepts a `String`,
  returns the matching `Direction` when valid, and falls back to
  `.right` with a `.warning` log when the value is unknown. A typo
  in a hand-edited config does not take the app down.
- **Action case**: a payload key that matches neither the canonical
  spelling nor an alias throws a `DecodingError.dataCorruptedError`.
  One `Keybind` either decodes exactly or not at all. The
  containing `SavedConfig` then drops just that keybind. See
  "Per-element tolerance" below.
- **Optional `SavedConfig` fields**: missing fields decode as `nil`
  and the runtime applies the matching default from
  `UserConfigDefaults`.

## Per-element tolerance

`SavedConfig` decodes its `keybinds` array one element at a time.
An element that throws is skipped with a `.warning` log (the
action key itself stays out of the log because it is hand-editable
text); every other keybind and every other field decodes normally. The custom `init(from:)` lives in an extension in
`Persistence/ConfigStore.swift`, so the memberwise initializer
still exists and `encode(to:)` is still synthesized. The wire
format is untouched.

This matters because `config.json` is shared across machines over
iCloud Drive. When a newer build adds an `Action` case and
`UserConfig.mergeNewDefaults` injects its default keybind, an older
build sharing the file meets a case key it has never heard of.
Before per-element tolerance, that one unknown key threw, the
`try?` in `ConfigStore.loadSavedConfig` returned `nil`, and the
older machine silently reset gaps, colors, excluded bundles and
every keybind to defaults, then pushed the reset back through
iCloud on its next save.

If every keybind is skipped, `keybinds` is empty and
`UserConfig.mergeNewDefaults` repopulates the full default table,
so the user gets working binds rather than none.

Remaining caveat: an older build that skips a newer action and then
saves writes the shared file without that keybind. The newer
build's `mergeNewDefaults` re-injects the default bind on its next
launch, but a *customized* chord for that action is lost. Nothing
else in the config is touched.

`KeybindDecoderToleranceTests` pins both halves:
`testUnknownActionKeyThrows` for the strict single-keybind decode,
and the `testSavedConfig...` cases for the skip-and-keep-going
behavior plus the unchanged encoded key set.

## Schema versioning

`SavedConfig` carries an optional `version: Int?`:

```swift
struct SavedConfig: Codable {
    let version: Int?  // nil for v1 (the implicit version)
    // ...
}
```

The field is declared but not currently emitted. `ConfigMigration.currentVersion`
is `1`; the encoder constructs `SavedConfig(version: nil, ...)` so
the encoded JSON does not gain a `version` key. This keeps the wire
format byte-equal for unchanged settings — important when a user's
config round-trips through iCloud sync between machines on
different HyprMac versions.

The first concrete schema bump will be the moment to start
emitting a value. The decoder already maps `nil → 1`; bumping to
v2 means setting `version = 2` on encode, adding a v1 → v2 migration
case in `ConfigMigration`, and updating `KeybindDecoderToleranceTests`
to round-trip both shapes.

## Monitor-config split

Two on-disk files:

- `~/Library/Application Support/HyprMac/config.json` — main config.
  Synced via iCloud Drive when the user enables sync (resolves to
  a symlink into `~/Library/Mobile Documents/com~apple~CloudDocs/HyprMac/`).
- `~/Library/Application Support/HyprMac/monitor-config.json` —
  per-machine settings. Local only, never synced.
  `maxSplitsPerMonitor` and `disabledMonitors` live here. These
  used to live in `config.json`, but per-machine settings round-tripping
  through iCloud Drive clobbered each machine's setup.

`ConfigMigration.resolveMonitorConfig` handles the migration: if
the local file is absent and the synced config has the old fields,
it adopts the synced values and returns `needsLocalWrite: true` so
the caller persists a local file. After one launch, the local file
is the source of truth and the synced fields are ignored.

## Default keybinds

`Models/DefaultKeybinds.swift` holds the built-in keybind table.
`UserConfig.mergeNewDefaults` injects new defaults into existing
saved configs at load time, so users who upgrade pick up new
keybinds without resetting their customizations. New default
actions go in `DefaultKeybinds.swift`; the merge handles the rest.

## Run a command

`runCommand(label:command:)` binds a chord to a program of the
user's choosing. The payload is two strings: `command` is the
command line, and `label` is the name shown in the settings list and
the `Hypr+K` overlay. An empty label falls back to `Run <program
basename>`. `command` is required — a keybind without it is skipped
by the per-element tolerance in `SavedConfig`. A missing `label`
decodes as `""`.

**No shell.** `CommandRunner` tokenizes the line in-process and hands
`Process` an executable URL plus an argument array. Nothing is passed
to `/bin/sh`, so pipes, `;`, `&&`, redirects, globs and `$VAR` are
inert — they arrive at the program as ordinary arguments. Point the
keybind at a script when you need any of those.

**Quoting.** Whitespace (including a non-breaking space) separates
arguments. `"..."` and `'...'` group an argument that contains spaces.
A backslash escapes the next character outside single quotes, so a
line cannot end in one. A leading `~` or `~/` expands to the home
directory, only at the start of an argument and only when unquoted.

**Program lookup.** A token containing `/` is used as the path; a
relative one is taken from the home directory, which is also the
child's working directory. A bare name is searched for in the app's own `PATH` first, then in
`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`,
`/usr/sbin`, `/sbin` — the fallbacks matter because a GUI-launched
app inherits a minimal `PATH`. The match must be a regular
executable file.

**Runtime.** The child starts asynchronously from the home directory
with the app's environment; stdout, stderr and stdin go to
`/dev/null`. Nothing about the command — its text, arguments, paths
or output — is written to the log. A non-zero exit logs only the
status number (`runCommand exited with status 3`).

There is no default binding. The action ignores key autorepeat, so
holding the chord runs the program once, and — like Launch App — it
is unavailable while tiling is paused.

## Hex color storage

`UserConfig.focusBorderColorHex` and `floatingBorderColorHex` are
`String?` — `nil` means "use the system default", a hex string like
`"007AFF"` means "use this exact color".

`NSColor.fromHex` returns `nil` on malformed input and logs a
`.warning`. Invalid color strings fall back to the system default
silently rather than crashing.

## Hand-editing config.json

Config lives at `~/Library/Application Support/HyprMac/config.json`
(delete to reset to defaults). Keybind entries look like:

```json
{ "keyCode": 123, "modifiers": { "rawValue": 1 }, "action": { "focusDirection": { "_0": "left" } } }
```

Restart HyprMac after editing. Example — bind Hypr+B to launch Safari:

```json
{ "keyCode": 11, "modifiers": { "rawValue": 1 }, "action": { "launchApp": { "bundleID": "com.apple.Safari" } } }
```

Example — bind Hypr+5 to an interactive screenshot:

```json
{ "keyCode": 23, "modifiers": { "rawValue": 1 }, "action": { "runCommand": { "label": "Screenshot", "command": "/usr/sbin/screencapture -i ~/Desktop/shot.png" } } }
```

**Modifier rawValues** (bitwise OR to combine — see
`Models/Keybind.swift`): `1` Hypr, `2` Shift, `4` Option, `8`
Control, `16` Command. Hypr+Shift = `3`, Hypr+Ctrl = `9`,
Hypr+Ctrl+Shift = `11`.

**Key codes** (decimal, Carbon `kVK_*`):

- Arrows: Left=123, Right=124, Up=126, Down=125
- Letters: A=0, S=1, D=2, F=3, H=4, G=5, Z=6, X=7, C=8, V=9, B=11,
  Q=12, W=13, E=14, R=15, Y=16, T=17, O=31, U=32, I=34, P=35, L=37,
  J=38, K=40, N=45, M=46
- Numbers: 1=18, 2=19, 3=20, 4=21, 5=23, 6=22, 7=26, 8=28, 9=25, 0=29
- Return=36, Space=49, Tab=48, Delete=51, Escape=53, Grave/Backtick=50

**Other config fields**: `gapSize`, `outerPadding`, `enabled`,
`focusFollowsMouse`, `excludedBundleIDs` (bundle IDs that never
tile — auto-float on discovery), `disabledMonitors` (monitor names
matching `NSScreen.localizedName`, excluded from tiling entirely),
`scratchpadTileByDefault` (windows sent to the scratchpad tile into
the layer instead of floating; no-fit windows float regardless),
`scratchpadRegionInset` (per-edge inset fraction of the scratchpad's
tiled region, 0–0.15; 0.06 default keeps the scrimmed border visible,
0 is edge-to-edge), `windowRules` (per-app workspace pins, below).

Find any app's bundle ID:
`mdls -name kMDItemCFBundleIdentifier /Applications/AppName.app`

## Window rules

`windowRules` pins an app's new windows to a workspace instead of
letting them land on whichever workspace is visible on the display they
opened on. Edit them in Settings → General → "Pin apps to workspaces",
or by hand:

```json
"windowRules": [
  { "bundleID": "com.spotify.client", "workspace": 9 },
  { "bundleID": "com.apple.MobileSMS", "workspace": 4 }
]
```

Rules are keyed by bundle id and hold one workspace each; a duplicate
bundle id in a hand-edited file resolves to the first entry. The pin is
read by `ActionDispatcher.pinnedWorkspace` at three moments:

- when a new window is admitted;
- when startup or Retile All redistributes every window
  (`WindowManager.startupPlacement`), where pinned windows form their
  own batches ahead of the per-screen ones so they claim their
  workspace's capacity first;
- on demand, through `Action.applyWindowRules` (Hypr+Shift+R, or the
  "Apply" button in the settings panel).

Between those passes a pin is not a tether: a window you move afterwards
stays where you moved it.

The manual pass (`ActionDispatcher.windowRuleMoves`) considers every
open window whose app holds a rule and sits on a different regular
workspace. Scratchpad members, minimized and Cmd-H'd windows, and
windows in native fullscreen are skipped. Capacity is counted as
admission counts it - floaters and hidden windows hold no tile slot -
but a full destination refuses the excess instead of spilling it onto
the next free workspace: the user named one workspace, so the refused
windows stay put and the pass beeps once. Moves go through
`WorkspaceOrchestrator.moveWindows`, which relocates the whole group and
retiles once; tiled windows take their frame from that retile, floaters
are carried to the destination's display or parked with their frame
saved when it is hidden.

A rule is skipped, and the window placed normally, when its workspace
falls outside 1–10 or when that workspace's home display is
disconnected or excluded from tiling. Apps in `excludedBundleIDs` never
tile, so a pin on one has no effect.

The array decodes with the same per-element tolerance as `keybinds`: a
malformed rule is logged and dropped, and every other setting in the
file survives it. Configs written before this field existed decode as
no rules.
