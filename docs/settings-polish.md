# Settings polish

## Evidence and scope

This pass starts from `origin/main` at `701c551`. The preserved hub checkout was not changed. Read-only inspection of the MacBook on September 14, 2026 found:

- `mouseHoverPollHz: 120` and focus-follows-mouse enabled.
- Dimming enabled at `0.1346203613281251`, persistent borders disabled, focus color `000000`, fade duration `0.13`, and corner radius `15`.
- The configuration file is an iCloud Drive symlink. Both direct settings edits and complete file reloads therefore need safe live-update behavior.

The running laptop debug app predates this pass. No app, preference, window, or process on the laptop was changed. Its log tail was read for context; no controlled runtime experiment was performed there.

## Hover response

The former refresh-rate slider controls **hover-to-focus checks during mouse movement**. `WindowManager` supplies `MouseTrackingManager.hoverThrottleInterval`; the mouse handler drops events that arrive too soon. It does not run a timer at the selected frequency and does no hover work while focus-follows-mouse is disabled.

| Before | After |
| --- | --- |
| A numeric 60–240 Hz refresh-rate slider | Hover response: Low 60 Hz, Medium 120 Hz, High 240 Hz |
| Frequency looked like an overall refresh control | Wording says it controls pointer-driven focus checks |
| Saved intermediate rates | Exact custom rate remains visible and preserved |

Medium retains the existing 120 Hz default. The minimum spacing between eligible checks is approximately 16.7 ms at Low, 8.3 ms at Medium, and 4.2 ms at High. These are throttle intervals, not guaranteed focus latencies: dropped events are not replayed if the pointer stops, and main-thread work can delay handling. The topmost-window cache also reuses results for up to 80 ms while the pointer remains within 10 points, so attempts do not equal expensive window-list queries.

Window discovery is separate: accessibility notifications request coalesced discovery, with a fixed 10-second reconciliation timer for missed events. Neither this timer nor display refresh, key handling, animation durations, or window sizing uses the hover setting.

Higher rates permit more hit-test attempts while the pointer moves. This establishes a work-versus-responsiveness tradeoff, but no energy or battery-life measurement was collected. The same tier remains active on battery and external power. A later optional battery override would need an injected power-state provider, explicit preference migration, and measurements. macOS provides IOKit power-source snapshots and limited-power notifications; there is no reason to add another recurring power poll.

### Rate compatibility

`mouseHoverPollHz` remains the stored integer. Existing 90, 150, 180, 210 Hz and manually configured values are not rounded to tiers. Selecting a tier explicitly replaces the value. Values below the pre-existing 30 Hz runtime floor remain stored and are labelled with their effective rate. File reloads now apply the saved hover value as startup does.

## Focus appearance

The default uses dimming and corner cues while the Hypr key is held. Persistent colored focus fills and full-window borders are off. The existing border renderer remains available as an opt-in because it also owns bounded red rejection feedback and existing users may deliberately use its colors.

| Setting | Before default | New default |
| --- | --- | --- |
| Dim inactive windows | Off | On |
| Dim amount | 20% | 13.5% |
| Dim slider | 5–60% | 0–27% |
| Persistent borders | On | Off |
| Corner cue color | Shared focus color, cyan by default | Neutral |
| Dimming/border fade | 220 ms | 130 ms |

Zach requested his current dim level at the midpoint. The new 0–27% range puts the observed 13.46% almost exactly halfway. Existing stronger saved amounts remain intact; opening settings does not clamp or rewrite them. The displayed percentage reports the saved amount, and using the slider chooses a value in the new range.

Window shape and key-press marks have separate controls. **Window corner radius** keeps the existing `windowCornerRadius` override and shapes only dimming cut-outs and optional window borders. **Mark roundness** shapes only the four Hypr-key marks; zero gives square marks and higher values round their corner arcs. The marks have their own visibility toggle and a 14-point design default. Changing either radius updates only appearance. Color is independent of the persistent border and defaults to white with a black contrast stroke. Both stroke widths are quieter than before (3-point foreground, 5-point contrast). The fixed corner entrance/release timings remain unchanged; the fade slider controls borders, dimming, and the scratchpad scrim.

Explicit saved dimming, border, color, radius, and fade preferences remain authoritative. Missing fields, fresh configurations, and Reset to Defaults use the new baseline. Error feedback still shows a red overlay shake and message after rejection even when persistent borders or corner cues are off. It does not shake application windows.

### Corner compatibility

The optional `focusBracketStyle`, `focusBracketColorHex`, and `focusBracketRadius` fields extend the existing configuration without renaming its keys. For an older file with no style field, an explicit focus-border color becomes the initial bracket color. Once the new style field is saved, an absent bracket color means neutral and never reimports the old border color. Thus the laptop's saved black cue is preserved until changed deliberately. Old builds can ignore the new fields, but may discard them if they rewrite the shared file; cross-version iCloud writes cannot preserve preferences unknown to the old writer.

### Window-radius research

Apple describes macOS 27 Golden Gate as giving windows a consistent, tighter radius. It described Tahoe's radii as varying with window style: larger toolbars get larger corners, while titlebar-only windows use smaller corners. These are standard-window design statements, not a guarantee for custom-shaped application windows. Sources: [WWDC26 Platforms State of the Union](https://developer.apple.com/videos/play/wwdc2026/102/) and [WWDC25 AppKit design](https://developer.apple.com/videos/play/wwdc2025/310/).

Apple's [WWDC25 window-corner slide at 7:30](https://developer.apple.com/videos/play/wwdc2025/310/?time=450) supplies numeric Tahoe values:

| Window style on macOS 26 | Radius |
| --- | --- |
| Titlebar | 16 pt |
| Compact toolbar | 20 pt |
| Toolbar | 26 pt |

No numeric Golden Gate radius was verified. Apple's linked macOS 27 Figma kit returned HTTP 403, and the Sketch page exposed no downloadable layer geometry. This pass retains the existing 16-point fallback for macOS 26 and later and the existing 10-point compatibility fallback for earlier versions. The former is a documented Tahoe titlebar value, **not** a documented Golden Gate universal value; the latter was not independently measured in this pass. The reset button is therefore labelled **Suggested**, not **OS default**. A controlled measurement on Golden Gate is still needed before choosing a different automatic value.

The MacBook's read-only OS inventory reports macOS 27.0, build 26A428. Its explicit 15-point HyprMac override remains untouched. A global manual correction remains useful, although one radius cannot perfectly match differently shaped windows simultaneously. There is no per-app override interface in this pass.

## Live-update boundary

The first aesthetic save could trigger a layout change through a file-watcher echo. The old layout subscriptions used `dropFirst().removeDuplicates()`: dropping the initial value left deduplication uninitialized. The first reload's unchanged gap, padding, split limits, and disabled-monitor values then reached retile or redistribution callbacks.

Two additional problems made updates inconsistent:

- `@Published` emits before storing the new value. Appearance callbacks that read the configuration instead of the emitted value could render the previous setting.
- Each start added another set of subscriptions, while stop left them installed. Repeated disable/enable cycles multiplied later callbacks.

Live updates now compare complete configuration snapshots with the initial state already recorded. Only changed layout fields invoke layout effects. Appearance changes use a dedicated visual path, without rebuilding window caches, setting application frames, assigning workspaces, or changing focus. The subscription is installed once, and file reloads are observed after their complete state has been applied.

Gap/padding, split limits, monitor enablement, and scratchpad region size still have their intended layout effects. Dimming, color, fade, corner radius, and border/corner appearance do not.

## Verification and remaining acceptance

The untouched baseline passed 796 tests, with 92 display-dependent skips and zero failures, using `scripts/test-isolated.sh --debug-variant`. This harness does not start the window manager and redirects configuration and caches into the build directory.

Final validation:

- Full isolated suite: **820 tests, 94 display-dependent skips, zero failures** (726 non-skipped passes). Log: `build/polish/final-tests.log`.
- Focused cadence, migration, configuration routing, radius independence, and wire-format tests passed during implementation. The future-style/neutral-color migration regression was observed failing, then passing after the fix.
- The old Combine operator order was reproduced independently: an initial value of 8 followed by an unchanged 8 reaches the old `dropFirst().removeDuplicates()` subscriber once. New production-observer tests verify unchanged reloads produce no layout effects.
- Display-backed tests for initial bracket paths, live appearance, and rapid hide/show compile but are skipped by the isolated harness. They require a later authorized GUI run.
- Debug and Release universal app builds **passed** and both contain arm64 and x86_64 binaries. They use the generated `build/polish/HyprMac.xcodeproj`, existing cached Sparkle dependency, `ARCHS='arm64 x86_64'`, and `CODE_SIGNING_ALLOWED=NO`. These are local verification builds, not signed distribution artifacts. Logs: `build/polish/debug-build.log` and `build/polish/release-build.log`.
- Generated project membership, bundle identities, and `git diff --check` passed. Release retains existing AX-notification cast warnings; both builds report the non-blocking absence of App Intents metadata.

Final review also fixed stopped-state handling: stop clears the held-key flag and hides brackets, and appearance updates cannot re-show them while disabled.

Deterministic routing tests establish the routing boundary; they do not establish visual quality on the MacBook. A later explicitly authorized live acceptance pass should adjust every appearance control while tiled/floating windows occupy multiple workspaces, confirm stable geometry and focus, test corners on light/dark content, and trigger a rejected operation to confirm red feedback remains visible.
