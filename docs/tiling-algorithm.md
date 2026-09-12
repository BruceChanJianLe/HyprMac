# Tiling algorithm

HyprMac uses a binary space partition (BSP) tree with dwindle layout.
This document is the algorithm walkthrough; for the orchestration
surface that drives it, see `docs/architecture.md`.

## Tree shape

One `BSPTree` per `(workspace, screen)` pair, owned by
`TilingEngine`. Each `BSPNode` is either a leaf carrying a
`HyprWindow` or an internal node with two children and a
`splitRatio` in `[0.15, 0.85]`. Leaves and internal nodes are
distinguished by:

- **leaf** = `window != nil` or both children are `nil`
- **internal** = both children are non-nil

Empty leaves are a transient state used during compact and prune;
outside those paths every populated tree has window-bearing leaves.

`splitRatio` is enforced at the property setter — direct writes
clamp to `[TilingConfig.minRatio, TilingConfig.maxRatio]`. Out-of-bounds
ratios would put the layout math into states it is not designed for.

## Dwindle layout

Each split picks the longer axis of the parent rect. By default the
new window goes on the right (horizontal split) or bottom (vertical
split); the one exception is a slot restoring a remembered boundary,
where the new window takes the side the old one vacated (see
**Ratio memory**). The pattern produces the characteristic dwindle
spiral on wide monitors:

```
   +---------+
   | A       |
   |         |
   +----+----+
   | B  | C  |
   |    +----+
   |    | D  |
   |    | etc|
   +----+----+
```

`togglesplit` (`Hypr+J`) overrides the dwindle direction on the
focused leaf's parent via `splitOverride`. The override survives
until the next sibling restructure (insert / remove on that node).

## Ratio memory

A native tab switch or a Cmd-H looks like a close followed by an open
a poll or two later. Without help, the window comes back at 50/50 and
the user's manual resize is gone.

When a leaf leaves a split, `BSPNode.remove` promotes the sibling and,
if the vanishing split was user-set and the sibling is a leaf, records
the boundary on it: `savedSplitRatio`, `savedChildWasLeft`, and
`savedSplitOverride`. The next `insert` on that leaf puts the new
window on the side the old one vacated and stashes the ratio in
`pendingSplitRatio` / `pendingSplitOverride`.
`TilingEngine.updateTreeMembership` calls `applySavedRatios` last, after
`clearUserSetRatios` and `resetSplitRatios`, so the restored boundary
survives the reset and comes back flagged `userSetRatio`.

Three limits are deliberate:

- **Only user-set ratios.** `adjustAxisRatio` writes min-size fudges
  without setting `userSetRatio`, and removals run before
  `resetSplitRatios`. Remembering those would pin a fudge forever.
- **Only leaves.** An internal sibling already carries its own split.
  Saving the outer ratio onto it would push the boundary into an
  unrelated pair of windows.
- **Only the pending fields are consumed.** A node that inherited a
  leaf's saved boundary on the way up is never a restore target, so a
  promoted subtree keeps the split it already had.

The memory has no expiry, so a Cmd-H and an unhide seconds later both
work. Whichever window next lands in that slot takes the boundary,
which is the intended trade: the slot is remembered, not the window.

## Smart insert

Plain dwindle always splits the deepest-right leaf. On constrained
monitors — typically tall vertical displays — the deepest-right
slot can fall below `TilingConfig.minSlotDimension` (500 px),
producing unusable windows.

`BSPTree.smartInsert` walks every leaf right-to-left
(`allLeavesRightToLeft`) and skips any leaf where the resulting
children would fall below `minSlotDimension` on either axis. The
first leaf that fits accepts the insert. On a vertical 1440 px-wide
display, this typically backtracks past the deepest-right leaves and
produces a 2×2 grid layout instead of a degenerate dwindle spiral.

If no leaf fits — the tree is genuinely full given the monitor
dimensions — `TilingEngine.onAutoFloat` fires and the window is
auto-floated.

## Max depth

`TilingConfig.defaultMaxDepth` is 3. A depth-3 tree has 8 leaves;
the smallest slot is 1/8 of the screen. Beyond depth 3, smart insert
returns no fitting leaf and the window auto-floats.

Per-monitor overrides live in `TilingEngine.maxSplitsPerMonitor`,
keyed by `NSScreen.localizedName`. The settings UI exposes this so a
user can ratchet a wide monitor up to 4 splits (16 slots) or a
vertical monitor down to 2 (4 slots).

## Two-pass layout

macOS apps with hard min-size constraints (Spotify, Messages, Xcode)
refuse to shrink past their floor. The first pass writes target
frames and reads back what the OS actually accepted. When pass 1
reveals an oversize, pass 2 redistributes the parent's split ratio.

The engine first captures every affected window's actual position and
size. `FrameSizingAttempt` applies each requested frame in resize–move–resize
order, retains AX write errors, and reads the complete layout back. Two
stable samples are required. Position and size may differ by at most one
AX point, but usable-screen containment, positive-area overlap, and the
configured gap are checked separately across every pair of windows.

Each attempt has a 0.36-second monotonic deadline and a 12-sample limit.
Time inside AX calls counts toward that deadline. Individual AX calls use
a 0.1-second messaging timeout; synchronous calls cannot be interrupted by
the Swift deadline. Stable off-target frames wait at least 0.24 seconds
before becoming a geometry rejection. Failed reads and superseded work
never become accepted geometry.

Only a known, stable size conflict permits a second pass.
`BSPTree.adjustForMinSizes` adjusts constrained ratios, and the final
adjusted layout goes through the same complete verification. If that pass
fails, the engine restores the prior ratio snapshot and writes the captured
original frames once, then verifies restoration. Results distinguish
accepted geometry, rejected geometry with verified restoration, and a
degraded state whose restoration could not be verified. Superseded work
does not restore frames over a newer operation.

Normal smart insertion can still auto-float a new window when no leaf fits.
The old post-readback overflow auto-floating path remains disabled. Target
insertion uses one candidate pass and one possible restoration, without
ratio adjustment, eviction, or automatic floating.

## Min-size memory

`MinSizeMemory` is the per-window record of the lowest accepted
size. macOS apps do not expose reliable `AXMinimumSize`; the engine
learns the floor from pass-1 readback.

Hysteresis on both ends:

- **Record (raise the floor):** when an oversize is observed, the
  recorded min is `max` of the existing value and the observed size
  on the affected axis. Sentinels above
  `usableMinSizeMaxPx` (10 000 px) are rejected — apps occasionally
  report `INT_MAX` when AX cannot resolve.
- **Lower (relax the floor):** an accepted size at least
  `lowerMinSizeAcceptedDeltaPx` (10 px) below the current bound
  becomes the new floor. Sub-pixel accepts cannot ratchet the floor
  down — without this, a one-time tight resize would over-eagerly
  relax our memory.

The memory mirrors back onto each `HyprWindow.observedMinSize` so
other subsystems (drag-swap fit check, floating toggle) read
consistent values.

## Swap

Direction swap (`Hypr+Shift+Arrow`) goes through
`canSwapWindows` first. The check:

1. Snapshot the tree.
2. Trial-swap the two windows with cleared `userSetRatio` flags.
3. Reset every internal node's `splitRatio` to the default so the
   trial layout matches what the actual swap will produce.
4. Ask `LayoutEngine.layoutCanAccommodateKnownMinimums` whether the
   resulting layout fits every recorded min size.
5. Restore the snapshot and return the answer.

The synchronous `swapWindows` path returns true only after verified
acceptance. A rejected attempt restores the prior tree and captured actual
frames, with restoration verified separately. Keyboard rejection retains
its existing feedback behavior.

## Pointer target insertion

`TiledDragHandler` owns a press snapshot and a deferred release. It captures
the actual frames of the source tree and visible floating occluders once.
A press must hit exactly one tile and no occluder. Floating and scratchpad
presses do not start tiled insertion.

The mouse-up event supplies the release point and Option state. After the
100 ms settle delay, a bounded read of the captured dragged window separates
manual resizing from movement. A width or height change greater than 20 AX
points produces a resize candidate. Position and size changes within one
point are ignored, so text selection does not rearrange unmoved windows.

An ordinary move chooses a target from the release point within the source
workspace and physical display. The nearest normalized target edge selects
left, right, top, or bottom insertion; ties use that order. Option at release
requests a same-tree swap instead. A release without a target restores and
verifies the captured frames. Cross-monitor and cross-workspace insertion
are excluded.

`BSPTree.candidateTree` clones the source, removes the dragged leaf, and
splits the target on the selected side. Horizontal splits create columns;
vertical splits create rows. The candidate preserves unrelated node state
and exact membership. Every leaf must satisfy Max Splits before candidate
writes. Restoration writes remain available when a candidate fails preflight.
This hard limit also applies to modifier swaps and manual resize candidates;
an existing tree deeper than a newly lowered limit is restored rather than
applied. Keyboard swapping retains its existing path.

The engine applies the candidate through the verified sizing transaction
and replaces the mapped tree only after all resulting frames are accepted.
Failure leaves the old topology in place and verifies actual pre-drag frame
restoration. Failed restoration is reported as degraded; stale work stops
without overwriting newer geometry. The finishing flag suppresses polling
through the settle delay and transaction, without a fixed expiry timer.

## `prepareTileLayout` / `prepareSwapLayout` / `prepareToggleSplitLayout`

These methods calculate layouts after provisional tree changes.
`prepareSwapLayout` and `prepareToggleSplitLayout` capture actual frames
and the prior tree state for a later verified `applyComputedLayout` call.
They currently have test callers; keyboard actions use synchronous verified
paths. A superseding operation invalidates prepared rollback data.

The synchronous paths (`tileWindows`, `swapWindows`, `toggleSplit`)
do not use `prepare*Layout` — they apply frames directly and own
their own snapshot/revert logic when needed.

## Known limitations

### Squishy-sibling swap rejection

When a swap squishes a "squishy" sibling — an app with no
AX-reported or readback-confirmed minimum size (Sidenote in the
canonical user setup) — the mathematical layout fits,
`overflowingWindows` reports no conflict, and the swap accepts. The
resulting compression may look visually wrong even though the
geometry is technically valid.

A "comfort band" rejection criterion was investigated and
deliberately deferred. Arbitrary thresholds risk false-rejecting
layouts that genuinely fit — Spotify needing 67 % of screen width
on a 1200 px monitor is a legitimate split, not a comfort
violation. The behavior is acceptable for now; future work would
either learn a per-app comfort minimum from accepted layouts or
expose a per-app override.

### Restored ratio versus the smart-insert fit check

Smart insert judges whether a leaf has room by splitting its rect
50/50, but a restored boundary is applied afterwards by
`applySavedRatios`. A remembered 0.85 can therefore starve the small
side of a slot that the fit check passed. This is the same exposure a
manual resize already has, so it is left alone.

### Tiling tree keying

`TilingKey` keys on screen-origin coordinates
(`x * 10000 + y`). If two monitors swap physical positions during a
reconnect, trees follow the position rather than the physical
display. Migrating to `displayID` keying is tracked but not done —
the change is risky in isolation because it interacts with
`WorkspaceManager.screenID` (also coordinate-based) and the
home-screen migration path in `handleDisplayChange`.

### Engine line count

`TilingEngine` is over the 350-line target documented in the
refactor plan. The action-method cluster (`tileWindows`,
`prepareTileLayout`, `addWindow`, `removeWindow`, `applyResize`,
`swapWindows`, `toggleSplit`, `resizeInDirection`,
`prepareSwapLayout`, `prepareToggleSplitLayout`,
`forceInsertWindow`, `canFitWindow`) plus verified drag capture/drop and
`retile` make up the engine's orchestration surface;
extracting them would require splitting the engine into a thin
orchestrator over a sibling type, which produces ceremony without
removing duplication. The decomposition is left for a future cycle.
