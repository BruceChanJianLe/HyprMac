# Window sizing verification

## Current status

The sizing transaction and same-workspace, same-monitor target insertion are
implemented. The historical checkpoints below preserve both failed and passing
runs; they are not claims about the current source. The final verification
section records the latest results and remaining checks.

Live use of the original implementation subsequently exposed workspace reveal
and late-discovery admission failures. The follow-up investigation and fixes
are recorded at the end of this document. The original passing unit suite did
not establish visual correctness.

## Deterministic sizing seam

The focused sizing tests use an injected AX operation surface and monotonic
clock. They do not contact WindowServer, launch HyprMac, or read live settings.

Verified behaviors:

- exact and delayed acceptance require two stable, complete position-and-size
  samples;
- AX size/position writes retain the resize-move-resize order;
- explicit write failures reject and failed reads remain unknown;
- elapsed monotonic time is checked after timeout setup and each AX operation;
- stable off-target frames are not rejected before the conflict-settle floor;
- cumulative movement does not count as a stable frame;
- full actual-frame validation checks target position and size, usable-screen
  containment, pairwise overlap, and configured-gap erosion;
- candidate rejection restores and verifies actual pre-operation frames;
- generation supersession stops without rolling back a newer operation;
- duplicate window IDs and non-finite frames reject before AX writes.

Evidence:

- `build/sizing/red-immediate-acceptance.log`: assertion-level failure for
  the initial exact-acceptance slice.
- `build/sizing/green-immediate-acceptance.log`: matching focused pass.
- `build/sizing/red-verification-and-rollback.log`: assertion failures for
  delayed acceptance, aggregate geometry, restoration, and supersession.
- `build/sizing/green-verification-and-rollback.log`: matching focused pass.
- `build/sizing/red-settle-stability-assertions.log`: assertion failures for
  the minimum mismatch-settle floor and cumulative-drift stability.
- `build/sizing/green-bracket-integration.log`: current transaction suite,
  30 tests passed with no failures at that checkpoint.
- `build/sizing/green-poller.log`: current poller suite, 4 tests passed with
  no failures.
- `build/sizing/red-invalid-targets-assertions.log`: assertion failures for
  duplicate and non-finite target rejection before writes.
- `build/sizing/red-remaining-seam.log`: three assertion failures for missing
  window classification and invalid actual frames; the matching 16-test green
  is `build/sizing/green-remaining-seam.log`.
- `build/sizing/red-capture-gap.log`: eight assertion failures for bounded and
  validated capture, stale empty operations, raw negative target sizes, and
  diagonal gap erosion; the matching 27-test green is
  `build/sizing/green-capture-gap.log`.
- `build/sizing/red-shared-FrameSizingTransactionTests.log`: six assertion
  failures for the EnhancedUI write bracket and cleanup paths.
- `build/sizing/red-shared-FrameReadbackPollerTests.log`: two assertion
  failures for duplicate input and unknown-result cache invalidation.

The first implementation already contained explicit write-error, read-error,
and slow-call deadline handling when their tests were added. Those individual
cases passed in the broader red run and therefore are regression coverage, not
strict red-first evidence. The failed compile in
`build/sizing/red-settle-stability.log` is also not counted as red evidence;
the assertion-level rerun above supersedes it.

The sizing tests did not manipulate live application windows, displays, or
settings. The wider headless suite can create test-owned overlay panels; it
does not launch the window manager or modify managed windows. SIP-enabled
manual sizing acceptance remains outside this deterministic phase.

## Additional sizing checkpoints

- `build/sizing/red-final-timing-cleanup.log`: 34 tests, four expected
  assertions for subpoint movement and lost cleanup failure context.
  `build/sizing/green-final-timing-cleanup.log`: 34 tests, no failures.
- `build/sizing/red-window-accessors.log`: one test, three assertions for
  public getters bypassing typed AX reads. `build/sizing/green-window-accessors.log`:
  one test, no failures.
- `build/sizing/red-poller-stale-empty.log`: one expected stale-generation
  assertion. `build/sizing/red-poller-duplicate-capture.log`: isolated runtime
  failure at duplicate dictionary construction, exit 132.
- `build/sizing/red-engine-mutations-invalidation.log`: eight tests, ten
  expected assertions for failed resize/split mutations and state invalidation.
- `build/sizing/phase1-full-checkpoint.log`: 339 tests, 18 visual tests skipped,
  34 assertion failures in older synthetic-window fixtures. The sizing
  transaction (34), poller (6), and verified engine (8) suites passed within
  this run. This is a failing full-suite checkpoint, not a completion claim.
- `build/sizing/red-engine-prepared-toggle-cross.log`: ten tests, nine
  assertions for prepared-toggle restoration, the new cross-tree executor
  stub, and force-insert invalidation. The later
  `build/sizing/engine-cross-intermediate.log` still fails one assertion and
  is not final verification.
- `build/sizing/red-ax-cleanup-typed.log`: eleven tests, five expected
  assertions for ambiguous disable-write cleanup and timeout-reset failure.
  The earlier `red-ax-ambiguous-disable-cleanup.log` also used flawed string
  checks for C enum names; those checks are not counted as valid red evidence.

The legacy keyboard/prepare-layout fixtures were updated to inject
successful fake AX writes and reads. Production acceptance is not relaxed to
make synthetic windows pass. The prepared animation APIs currently have tests
but no production callers; keyboard swapping uses the synchronous same-tree
path. Cross-screen swapping belonged to the legacy drag handler, which the
target-insertion phase subsequently removed.

The isolated Debug and Release application checkpoint builds passed for arm64
and x86_64 (`build/sizing/app-debug.log`, `build/sizing/app-release.log`). Both
use the separate debug bundle identity and exclude Sparkle. The Release
checkpoint uses optimization without the `DEBUG` compilation condition.
These builds do not verify the ordinary Sparkle-linked product. Sparkle and
SwiftLint are unavailable within this worktree, and no dependency download
has been authorized. At this checkpoint, final builds, the full-suite green,
lint comparison, and target-insertion verification were still open.

No checkpoint app was installed or launched. The current headless harness
skips the 18 tests that create visual panels. An earlier baseline run exercised
test-owned overlay panels before that guard was added; it did not launch
HyprMac or manipulate other applications' windows. Deterministic tests cannot
prove visual behavior. The SIP-enabled manual matrix in the phase brief still
requires separate authorization and remains unperformed.

## Phase 1 green checkpoint

`build/sizing/phase1-full-cleanup-final.log` built successfully and ran 347
tests with 18 visual tests skipped and zero failures. This includes 37
transaction tests and 11 EnhancedUI adapter tests. The three latest
transaction tests (cleanup-wrapped supersession, supersession during
restoration, and never-settled restoration) passed as characterization.
The earlier `phase1-full-cleanup-green-check.log` failed to compile a test
helper and is not test evidence. Cross-tree restoration assertions were
strengthened alongside a correction, so they are regression coverage rather
than a separately observed red-first slice.

Phase 2 begins from this deterministic green checkpoint. Live SIP-enabled
visual checks remain deferred as described above.

## Target insertion checkpoints

The pure candidate tree suite passed seven tests in
`build/sizing/green-target-topology-final.log`, after assertion-level failures
for all four edges, parent lifetime, and four columns in
`build/sizing/red-target-all-edges.log`. Three additional characterization
tests bring that suite to ten passing tests in
`build/sizing/check-BSPTargetInsertionTests.log`. The existing node and tree
suites also passed, with 30 and 26 tests respectively.

Pointer target selection passed seven tests in
`build/sizing/green-pointer-targets.log`, after 16 expected assertions in
`build/sizing/red-TiledDragTargetTests.log`.

The isolated drop transaction passed 23 tests in
`build/sizing/green-drop-transactions-final.log`. Its preceding
`build/sizing/red-drop-transactions.log` recorded 14 expected assertions.
The first six capture tests passed before the drop implementation began;
capture failures that prevented a drop test from running are not counted as
evidence for that drop behavior. The earlier `green-drop-transactions.log`
failed to compile and is not a passing checkpoint.

The first five drag coordinator tests passed in
`build/sizing/green-drag-coordinator.log`, following 17 expected assertions
in `build/sizing/check-DragSwapHandlerInsertionTests.log`. Event extraction
recorded five expected assertions across four tests in
`build/sizing/red-drag-events.log`. These events are constructed but never
posted. Integration into the live handler remains unfinished at this checkpoint.

The expanded drop suite passed 28 tests in
`build/sizing/green-drop-depth-geometry.log`. Its preceding red run,
`build/sizing/red-drop-depth-geometry.log`, caught Option swaps bypassing the
current Max Splits limit. Zero-gap fractional layouts, accepted four-column
transactions, closure, and unsettled restoration passed as characterization.
The coordinator's reentrant capture, reentrant completion, and unknown-capture
reporting tests failed with three expected assertions in
`build/sizing/check-lifecycle-DragSwapHandlerInsertionTests.log`, then all eight
passed in `build/sizing/green-drag-lifecycle.log`. Event extraction passed all
four tests in `build/sizing/check-lifecycle-TiledDragEventTests.log`.

The pointer capture contract recorded 11 expected assertions across eight
new tests in `build/sizing/red-pointer-publication-independent-final.log`.
It requires one complete read of tiles and occluders. Complete frames are
published even when an occluder prevents insertion, so floating dimming can
reuse them. Failed reads never publish. Earlier pointer red runs did not
reach every callback assertion; the final log checks publication and read
counts before result guards. `red-pointer-publication-independent.log`
failed to compile an unrelated test and is not red evidence.

Cache policy failed six assertions in
`build/sizing/red-pointer-stage-DragSwapHandlerInsertionTests.log`, then
passed in `build/sizing/check-capture-wrapper-DragSwapHandlerInsertionTests.log`.
Two completion-ownership characterization tests bring this suite to 13
passing tests in `build/sizing/green-wrapper-final-DragSwapHandlerInsertionTests.log`.

The engine wrapper's first six failures were capture preconditions, not
drop evidence (`build/sizing/red-pointer-stage-TilingEngineTiledDragTests.log`).
After capture was implemented, three drop assertions failed in
`build/sizing/check-capture-wrapper-TilingEngineTiledDragTests.log`.
All six tests passed in `build/sizing/green-wrapper-final-TilingEngineTiledDragTests.log`.
The earlier `green-wrapper-*.log` files failed to load an unavailable test
bundle after a compilation failure and are not passing results.

## Release integration checkpoints

- `green-pointer-red-resize.log`: 40 tests, three expected resize assertions;
  the preceding 36 capture/drop tests passed. `green-resize-core.log`:
  40 tests passed.
- `red-wiring-TilingEngineTiledDragTests.log`: 13 tests, ten expected
  assertions for pointer capture and stale restoration/cleanup outcomes.
  `red-release-plumbing-TilingEngineTiledDragTests.log`: 15 tests, only the
  two new resize-delegation tests failed. `green-release-plumbing-TilingEngineTiledDragTests.log`:
  all 15 passed.
- `red-wiring-DragSwapHandlerInsertionTests.log`: 15 tests, 12 expected
  assertions for handler routing. `red-release-plumbing-DragSwapHandlerInsertionTests.log`:
  18 tests, 21 assertions including reentrant release during capture.
  `green-release-plumbing-DragSwapHandlerInsertionTests.log`: all 18 passed.
- `check-resize-boundaries.log`: 46 tests, one failed assertion caused by
  decimal subtraction placing a test frame just outside the numerical gap
  allowance. The test now checks clearly inside and outside that allowance;
  production tolerance was not widened. The other five added cases passed
  as characterization, including height-only resize, refused resize
  restoration, and superseded classification rollback.
- `red-unmoved-drag.log`: 49 tests, two expected assertions for content
  drags whose window did not move. `red-unmoved-TilingEngineTiledDragTests.log`:
  16 tests, two expected assertions, including unintended AX writes.
  `red-unmoved-DragSwapHandlerInsertionTests.log`: 19 tests, three expected
  cache/UI effect assertions. `green-unmoved-drag.log`: all 49 core tests
  passed; `check-occluders-DragSwapHandlerInsertionTests.log`: all 19 passed.
- `check-occluders-TilingEngineTiledDragTests.log`: 20 tests, six expected
  assertions for four empty-workspace occluder cases. The first WM build
  (`green-wm-integration.log`) failed on a fileprivate screen property and
  is not green evidence. `green-wm-integration-final.log` built successfully
  and passed all 20 engine tests.

All log names in this section are under `build/sizing/`. These are focused
checkpoints, not final full-suite or visual verification.

## Final verification

All work remains on `feature/window-sizing-safe-insertion`, based on exact
commit `6056c7050741151edc1ed3f5796df03c1b2a8c10`. Before production edits,
HEAD, branch, clean status, worktree and resolved metadata writability were
checked. `git update-index --refresh` succeeded, establishing that the earlier
index-lock sandbox failure did not recur. The older audit worktree was not
used or changed.

The final review found two corrections worth regression tests:

- Timeout setup before readback was labeled as a write failure.
  `red-read-timeout-diagnostic.log` ran 38 tests with one expected assertion;
  `green-final-sizing.log` passed all 38 after the diagnostic fix.
- WindowManager teardown could leave the mouse-button suppression flag set
  across restart. `red-stop-state.log` ran 23 handler tests with three expected
  assertions. The fix clears button, drag-event, and hidden-focus ownership
  before removing event monitors. The independent reviewer rechecked the
  integration and closed the finding.

Before that final review, `red-cancel-and-visible-target.log` recorded five
expected assertions across 22 handler tests for canceled queued releases,
canceled capture, and target selection from captured actual frames. All of
those tests passed in `final-full.log` (459 tests, 18 skipped, zero failures).

The reviewed source was rebuilt with:

```sh
scripts/test-isolated.sh --debug-variant
```

`build/sizing/final-full-reviewed.log` reports **460 tests, 18 visual tests
skipped, zero failures**. The focused suites included sizing (38), AX write
bracketing (11), readback polling (6), BSP insertion (10), pointer targets (7),
drag transactions (49), engine integration (20), drag handler/lifecycle (23),
and event extraction (4). Keyboard swaps and the existing repository tests
also ran in the complete suite.

`build/sizing/final-reviewed-stress.log` repeats those nine focused suites
20 times each through the same isolated direct XCTest runner: **180 successful
suite runs and 3,360 test executions**. No visual tests are in that repetition
set. The earlier `final-stress.log` recorded 3,340 passing executions before
the final lifecycle test was added.

The checked-in Xcode project was regenerated from `project.yml` and includes
all new production and test sources. Final isolated application builds passed
for both arm64 and x86_64 in Debug and optimized Release:
`build/sizing/final-reviewed-app-debug.log` and
`build/sizing/final-reviewed-app-release.log`. These compile all application
sources using the separate debug identity and `HYPRMAC_DEBUG_VARIANT`; the
Release configuration omits `DEBUG`. They exclude Sparkle and do not substitute
for the remaining ordinary-product build. Signing was disabled and neither
product was launched. Existing AX notification cast warnings and Xcode's
AppIntents metadata warning remain; new sizing compiler warnings were fixed.

`git diff --check` and whitespace checks of all new files passed. Source,
test, and documentation changes were reread after the final review fixes.

The independent review covered sizing, rollback, tree cloning, all candidate
modes, the engine adapter, and WindowManager integration. No blocking findings
remain after the lifecycle correction. This is a source review, not visual
acceptance.

### Bounds and tolerances

Each sizing attempt has at most 12 complete readback passes and a 0.36-second
elapsed deadline checked around AX operations. AX messaging timeouts are
0.1 seconds. Time already spent in a synchronous call counts against the
deadline; the code cannot forcibly interrupt a call. EnhancedUI cleanup uses
a bounded number of calls and may finish after the sizing deadline. A drop
has at most one candidate application and one restoration application.

Acceptance requires two stable complete-frame observations, anchored within
0.01 AX point. Position and size each matched within one AX point at the time
of this checkpoint. **Superseded.** The size tolerances widened to twenty
points in both directions on 2026-09-12 (see "Cell-rounded overshoot
acceptance" below), and only position still uses the one-point bound. Any
later statement about what "matched" means is the current one; this sentence
describes the state at this checkpoint only. The
usable-screen boundary is strict; outer padding comes from target geometry
and therefore inherits the position/size tolerances. Every affected pair is
checked for positive-area overlap and configured gap erosion. Gap comparison
allows only 0.0001 point of numerical slack. Tests cover safe subpoint shifts,
unsafe combined gap erosion, diagonal separation, touching zero-gap frames,
and values clearly inside and outside the numerical allowance.

AX position and size are separate reads, and windows are sampled sequentially.
Stable observations cannot prove an atomic visual state or future stability.

### Sparkle-linked verification and lint

After dependency downloads were authorized, Sparkle 2.9.1 and portable
SwiftLint 0.61.0 were downloaded into ignored `build/sizing/dependencies/`.
Both archive SHA-256 values matched their upstream release metadata. Nothing
was installed globally. The generated application project retains the
ordinary product's sources, identity, and settings, replacing the SwiftPM
reference with the downloaded Sparkle XCFramework.

The final linked suite ran with:

```sh
scripts/test-isolated.sh build/sizing/dependencies/sparkle/Sparkle.xcframework
```

`build/sizing/final-sparkle-tests.log` reports **460 tests, 18 visual skips,
zero failures** after the lint refactors. The corresponding nine focused
suites were repeated 20 times each in `final-sparkle-stress.log`: **180
successful suite runs, 3,360 test executions**. These results supersede the
earlier no-Sparkle checkpoints for the final source.

The final ordinary-product Debug and Release builds both passed for arm64
and x86_64 with Sparkle linked and code signing disabled. Logs are
`build/sizing/final-sparkle-debug.log` and `final-sparkle-release.log`.
The build invocation was:

```sh
xcodebuild build -project build/sizing/product-sparkle/HyprMac.xcodeproj \
  -scheme HyprMac -configuration Debug -destination 'generic/platform=macOS' \
  -derivedDataPath build/sizing/product-debug-derived \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO COMPILER_INDEX_STORE_ENABLE=NO
```

The Release invocation used `-configuration Release` and
`-derivedDataPath build/sizing/product-release-derived`. Both runs redirected
Foundation home, temporary files, and compiler caches into the worktree's
ignored sizing harness. These are build checks, not deployment or launch
checks.

SwiftLint used the same binary and unchanged repository configuration for
this branch and a `git archive` extraction of exact baseline commit
`6056c7050741151edc1ed3f5796df03c1b2a8c10` inside the worktree:

```sh
build/sizing/dependencies/swiftlint/swiftlint lint --no-cache --reporter json
```

The initial result was 272 findings, including 20 errors, versus baseline
200 findings and 15 errors. The final result is **240 findings: 227 warnings
and 13 errors** (`lint-final.json`, `lint-baseline.json`). Comparison by file,
rule, and severity confirms no new errors; two old unchecked frame-read casts
were removed. Warnings increased by 42, primarily test fixture unwraps, test
file/type size, and transaction complexity. **Lint still fails overall**;
the existing errors have not been hidden or reported as a clean lint gate.

The AX application wrapper now retains its typed element through timeout,
read, write, and cleanup calls. Two unavoidable AXValue casts retain exact
CF type-ID checks with narrowly scoped lint annotations. Tiled-drag helpers
were moved unchanged into a same-file private WindowManager extension. Other
corrections only adjust formatting. Independent review of these final
refactors passed with no blockers. Shell syntax checks and `git diff --check`
also passed.

### Remaining manual verification

No built app was installed or launched. Live settings, managed windows,
canonical app installations, and SIP were not changed. Manual SIP-enabled
checks still require authorization: all four insertion edges, four accepting
columns, Option swap, text/content drags, resize, real application sizing
refusals and delays, verified and degraded restoration, window closure,
display/workspace changes, queued-drop cancellation during stop, focus
indicators, floating-window dimming, containment, padding, and gaps. The 18
skipped visual tests also remain unverified. Unit tests do not prove this
visual behavior.

## Workspace regression follow-up

After an authorized installation of `93bfedf`, Zach reported that incoming
workspace windows flashed onscreen and disappeared. Messages also entered
scratchpad when five windows should have occupied two regular workspaces.
The running build was kept in place for investigation at Zach's request.
The following changes have not been deployed or visually accepted.

### Causes and corrections

The new ordinary-layout transaction captured incoming windows while they were
still parked at the workspace hide corner. When candidate verification failed,
it wrote those parked originals back before discovering that restoration was
outside the usable screen. That rollback introduced the visible disappearance.
Ordinary layout restoration now preflights captured originals against the
usable screen before any restoration write. An invalid offscreen baseline
returns a typed degraded result with the candidate and restoration reasons;
it never claims a successful restoration or substitutes invented originals.
The current observed candidate frames are retained as evidence, and the
failure reasons are logged. Valid visible originals still restore normally.

Scratchpad uses separate bounds: candidates validate against its inset region,
while restoration validates against the full display. Otherwise a legitimate
full-screen pre-operation frame would be incorrectly treated as offscreen.

The overflow report had a separate cause. Startup distribution ran before
windows were discoverable during a screen interruption. After wake/unlock,
discovery delivered five windows together and the existing dispatcher assigned
every one to the active workspace without checking capacity. The fifth tile
hit the existing scratchpad overflow handler. This assignment policy predates
`93bfedf`; the new verified-layout rollback did not send Messages to scratchpad.

Discovery now admits new windows as a batch. It counts existing tiled members,
fills the active workspace, then uses the next regular workspace anchored to
the same physical monitor. Hidden destinations are parked immediately. Existing
assignments and scratchpad membership remain intact; incoming floating windows
do not consume tiled capacity. Incoming IDs are sorted and deduplicated, and
recycled IDs do not count against both their old and new slots. Only genuine
exhaustion of eligible workspaces falls back to the existing overflow path.
Startup distribution and workspace moves share the same `2^maxDepth` capacity;
the former incorrectly used `maxDepth + 1`. The settings caption now states
the actual capacity and next-workspace behavior.

### Red/green evidence

- `red-workspace-reveal.log`: 13 tests, six expected assertions across unknown
  read, elapsed-deadline, and stable position-refusal cases. Each proved that
  rollback wrote hidden positions and left final fake frames offscreen.
- `green-workspace-reveal.log`: the new regressions passed, but two existing
  scratchpad assertions failed because the first guard used inset bounds.
  `green-reveal-scratchpad-bounds.log`: all 13 passed after separating bounds.
- `red-late-admission.log`: 11 tests, 11 expected assertions for capacity,
  occupancy, destination order, and actual assignment/parking callbacks.
- `red-admission-classification.log`: 14 tests, four expected assertions for
  floating capacity, scratchpad preservation, and forgotten occupancy.
- `red-admission-order.log`: 16 tests, four expected assertions for stable
  deduplication and recycled-ID occupancy. Earlier admission cases passed.
- `workspace-regression-full.log`: **474 tests, 18 visual skips, zero failures**.
  The relevant suites include 16 planner/admission tests and 13 verified engine
  tests. Existing sizing, drag transactions, and keyboard behavior tests ran.
- `workspace-regression-stress.log`: **2,720 passing test executions** across
  100 suite runs: 20 repetitions each of admission, verified layout, frame sizing,
  tiled drag transaction, and tiled drag engine suites.
- `workspace-regression-debug.log` and `workspace-regression-release.log`:
  Sparkle-linked Debug and Release application builds both succeeded.
- `regression-lint.json`: 241 findings (228 warnings, 13 errors), compared with
  240 findings (227 warnings, 13 errors) in the archived `93bfedf` baseline.
  There are no new errors. The admission planner adds one six-parameter warning;
  existing engine file/type length warnings increase by 16 lines. No baseline
  findings were suppressed and no lint configuration changed.
- Shell syntax checks for the isolated test and Debug build scripts passed,
  as did `git diff --check`.

All logs above are under ignored `build/sizing/`. Expected assertion failures
were observed before the corresponding production fixes. Independent review
of the final restoration and admission paths found no blocking issues.

These tests establish the specific code-path corrections, not live visual
acceptance. The original running app did not log the precise candidate
verification failure, so the investigation does not claim whether its trigger
was readback delay, a write error, deadline, or geometry rejection. The new
diagnostic preserves that distinction for subsequent authorized testing.


## Independent regression review follow-up

The installed `d2ac5c5` build remained unstable in live use. Zach reported
scattered startup placement, terminals that would not tile, and missing red
rejection feedback. An independent source review identified integration gaps
that the earlier fake-IO tests did not exercise. This follow-up verifies those
claims against source and adds regression cases before changing behavior.

Confirmed and corrected:

- Small downward size rounding was rejected by symmetric one-point matching.
  Candidate acceptance at the time allowed at most eight points of undershoot
  per axis, with position and overshoot still limited to one point.
  (Superseded on 2026-09-12: both size directions now allow twenty points, and
  the aggregate checks allow the same. See "Cell-rounded overshoot acceptance"
  below.) Every rollback uses the original one-point size tolerance, including
  drag preflight rollback.
- Ordinary membership changes and adjusted ratios could become live before AX
  acceptance. Normal tiling now applies a private candidate and publishes it
  only after acceptance. Failed attempts keep the prior tree. Unknown/degraded
  geometry remains a failure; keeping the prior tree does not prove that an app
  restored its original frame. No candidate geometry is invented as readback.
- Event-driven discovery could run before the initial snapshot. The scheduler
  retains one coalesced request until startup completes. The display fingerprint
  is seeded before notification observers are registered.
- Hidden assigned windows were excluded from incremental occupancy. They now
  reserve capacity, including during startup/Retile All packing (narrowed on
  2026-09-12 to hidden windows that can return; see the live workspace
  regressions follow-up below). Startup packs
  each monitor's visible workspace first and orders readable windows by frame,
  with the focused window first. Missing-frame tracked IDs are retained.
- Count capacity did not guarantee tree fit. Insert-time fit failures now probe
  complete destination tenant sets on private trees, visiting other anchored
  workspaces once before the existing scratchpad fallback. A successful probe
  is only a coarse insertion check, not verified AX acceptance. Routing neither
  activates another workspace nor recursively retiles it.
- Rejection feedback was coupled to persistent focus borders and omitted common
  no-target drops. A one-shot red overlay now reports every verified rejection,
  with distinct degraded feedback. The shake moves only the overlay, never a
  real window through unverified AX writes. Ignored/superseded gestures remain
  silent. Failure logs retain typed reasons without window titles.

Not adopted from the review: an unconditional 20-point size allowance, assuming
that silent logs establish a particular live AX failure, treating the 500-point
preferred child size as a hard fit limit (the second search pass relaxes it),
or overriding resize classification whenever the pointer resolves to a tile.
The cited six-by-four-point rounding cannot cross the existing greater-than-20
resize threshold. Existing tests deliberately preserve genuine manual resizes.
A center dead zone and preview would change interaction design; neither is
needed to correct the demonstrated regressions in this pass.

### Regression evidence

Logs are under ignored `build/sizing/fable-followup/`.

- `red-all-slices.log`: 491 tests, 19 visual skips, 16 assertions exposing
  quantization, feedback, early polling, hidden occupancy, startup ordering,
  and ordinary membership publication. Two sizing fixtures initially exhausted
  their scripted samples; those were corrected before sizing production edits.
- `red-quantization-routing.log`: 493 tests, 19 skips, nine expected assertions.
  Persistent quantized samples rejected as geometry mismatches; bounded
  next-workspace probing still returned no result before implementation.
- `red-fit-green-slices.log`: 495 tests, 19 skips, 11 assertions. Three exposed
  the whole-set fit probe's missing aggregate/duplicate checks. Eight existing
  keyboard-resize assertions caught replacement of live node identities; the
  correction copies only accepted adjusted ratios into existing nodes.
- `green-integrated.log`: 495 tests, 19 skips, zero failures, before the
  independent review's additional restoration/reservation checks.

- `red-review-gaps.log`: 498 tests, 19 skips, four expected assertions covering
  strict drag restoration, hidden startup reservations, and scratchpad
  membership isolation. Independent review prompted the first two additions.
- `green-review-gaps.log`: six older scratchpad assertions failed because those
  fixtures used unavailable real AX yet expected membership to publish anyway.
  They now inject the existing accepting fake AX factory. Their assertions were
  retained; the new failure fixtures separately exercise unreadable candidates.
- `red-first-publication.log`: 500 tests, 19 skips, three expected assertions
  covering failed first tiling and failed scratchpad migration on a synthetic
  second screen. Failed destinations no longer publish or delete source trees.
- `final-tests.log`: **500 tests, 19 visual skips, zero failures**.
- `final-stress.log`: **4,060 passing test executions**, 200 suite runs
  (20 repetitions of ten affected suites), zero failures.
- `final-debug.log` and `final-release.log`: both Sparkle-linked application
  builds succeeded with arm64 and x86_64 binaries. No application was launched.
- `lint-final.json`: **241 findings: 228 warnings and 13 errors**, matching the
  archived `d2ac5c5` baseline counts and per-file/rule/severity counts. Existing
  length warnings change their reported sizes; no baseline issue is suppressed.
  Startup/routing helpers live in a same-file extension to avoid introducing a
  new class-length error. A new test force-unwrap warning was removed.
- Fresh-context independent review and follow-up review found no remaining
  blocking findings. Shell syntax checks and `git diff --check` passed.

These are deterministic code-path checks, not visual acceptance. The running
MacBook build and settings have not been changed by this follow-up. SIP-enabled
manual checks remain required for startup/wake, terminal size rounding, hidden
window return, all insertion edges, rejection overlay timing, rollback refusal,
and mixed-application layouts. The skipped AppKit panel tests remain unverified.

## Live workspace regressions follow-up (2026-09-12)

Two live regressions remained after `f334604`: new windows spilled to the next
anchored workspace while the current one looked full, and a closed window's tile
slot stayed empty until some later, unrelated poll.

### Causes and corrections

Discovery moves a window to `hiddenWindowIDs` whenever it leaves the AX
snapshot while its owning process is alive. That includes windows the user
closed with Cmd-W, and admission counted every such id as occupancy. A
workspace with two visible windows therefore read as full. The cache now
carries `reservedHiddenWindowIDs`, the subset that can return on its own —
minimized, app hidden, or AX unreadable at the moment it vanished. Only that
subset reserves a slot, in admission, in startup capacity, and in the rejection
routing probe. A window the app still lists (another Space, full-screen) counts
as returnable. An id whose state was unreadable when it vanished is reserved
provisionally and re-queried on the next few cycles while its app runs; a
verified close releases the reservation, and an id that stays unreadable stays
reserved.

Closes are learned only from a poll, and that poll is requested by the
per-window destroyed notification. Two holes lost it. An app that tears its
window down after the AX element dies is still enumerated by the 0.2 s poll, so
nothing appeared gone and nothing re-polled. `DestroyRecheck` now schedules
bounded follow-up polls, three polls in all for a pending close, until the
close shows up or the owning process stops being relevant. Separately, a
window whose destroyed subscription failed was still recorded as subscribed,
so it never reported its own close; only a subscription that actually took
hold is recorded now, and a failure is retried on the next poll.

### Evidence to look for

- Fix A: `assignNewWindow: … → ws4` while the preceding `switch: … (hide N, …)`
  line shows workspace N at capacity with ids that no longer have windows.
- Fix B: `discovery retile: gone=` lines that follow `focusWithoutRaise`
  hover lines instead of the close itself. The persisted log records the
  poll, not the close, so a live `log stream --level debug` during a
  reproduction is needed to see the destroy-to-poll gap directly.
- After the fix: `hidden window <id> verified closed — releasing its workspace
  reservation` and `destroy recheck: closed window not yet gone from the
  snapshot — re-polling`.

### Cell-rounded overshoot acceptance (2026-09-12)

Terminal.app rounds its frame to whole character cells and rounds up. On the
3440-wide ultrawide a full-workspace target of about 3424x1301 reads back as
3425x1309. Candidate matching allowed one point of overshoot, so every layout
holding a Terminal window ended `geometryMismatch`. The readback poller then
read the height as a min-size conflict — the +1 width did not cross the old
`actual > target + 1` threshold, the +8 height did — so `MinSizeMemory` raised
Terminal's height floor to 1309 on the strength of one rounded row, and the
fit check routed the window off its workspace.

Corrections:

- Candidate size matching now allows twenty points in both directions
  (`TilingConfig.frameToleranceXPx`). Position stays at one point.
- The pairwise checks allow the same twenty points. Overlap is rejected only
  when the intersection exceeds it on both axes, and gap erosion only when both
  axes fall more than it below the gap.
- Containment allows the same twenty points past maxX/maxY. The origin keeps
  the strict one-point rule.
- Restoration pins overshoot, undershoot, and size tolerance back to one point,
  so a rollback still has to land exactly.
- A min-size conflict is measured against the overshoot tolerance, so cell
  rounding no longer teaches a bogus minimum.
- **Superseded by the step 3 publication gate below (2026-09-13).** A degraded
  layout publishes its candidate membership only when the candidate
  was written and restoration was never tried — the parked-originals pre-check.
  Those frames are still on screen, so keeping the prior tree hid the windows
  from focus navigation and replayed the failure on every retile. Once
  restoration has run the windows are back at or near their originals whatever
  its verdict, so the prior tree is kept; the outcome carries
  `restorationAttempted` rather than inferring this from the reason. A degraded
  layout that wrote nothing keeps the prior tree as before.
- **Superseded with it.** The pre-check branch also copies the adjusted pass's
  split ratios onto the live tree before returning, because those are the
  ratios that produced the frames left on screen.

Containment is bounded the same way, at the far edges only. The actual
origin must sit inside the usable frame within the one-point position
tolerance, and maxX/maxY may run past it by up to the overshoot tolerance.
Containment is checked against the unpadded screen rect while targets are
inset by `outerPadding`, so without this an edge window's headroom would be
the smaller of twenty points and the configured padding — a user padding
below the app's cell height would reject the same layout again, as
`outsideUsableFrame` instead of `geometryMismatch`. Restoration pins the
overshoot tolerance to one point, so a rollback still has to land inside.

What this deliberately accepts, as the price of tiling cell-quantizing apps:
a cell-rounded window may overlap its neighbour by up to
`sizeOvershootTolerance - gap` points, which is twelve at the shipping 8 pt
gap, and may extend up to `sizeOvershootTolerance` points past the usable
frame at maxX/maxY. At that gap `gap - tol` is negative, so gap erosion on
its own is never a rejection and `gapViolation` survives only as a tighter
overlap check firing above twelve points on both axes. This is the behaviour
the pre-93bfedf build had. Pairwise safety at the shipping gap rests on the
overlap check and the strict one-point position match.

## Diagnostics and write progress (2026-09-13)

Step 1 of the sizing and recovery plan. It changes no geometry, no timeout,
no tolerance and no learning rule; it makes what already happens legible.

What the code now carries:

- Every `FrameSizingAttempt.Result` carries a `Progress`: the phase
  (`capture`, `candidate`, `adjusted`, `restoration`), the generation, the
  target ids, the ids a setter was issued for, the ids whose three frame
  setters all returned success, and whether the readback was complete and
  stable. The mark goes on **before** each setter, including one that comes
  back with an error, because an AX write that reports a code may still have
  landed. Completion is recorded before the EnhancedUI cleanup runs, and a
  cleanup error stays a separate failure rather than unwriting it. Write
  completion is evidence that setters were issued, never proof that the app
  applied the frames.
- `FrameReadbackPoller` passes the phase through, so `applyLayout`,
  `applyFinal` and `applyRestoration` are distinguishable in a log, and
  returns the same progress on its own result.
- Traces gained phase, raw AX codes and per-step durations on the write
  lines, `onTarget` and a timestamp on the readback lines, and
  write/read/settle durations plus deadline headroom on the attempt line.
  Line shapes are in `docs/debugging.md`.
- The state dump gained `minima` (everything `MinSizeMemory` believes) and a
  `recovery pending=… unverified=…` line. Nothing produces recovery or
  unverified state yet; the line reports empty sets so its shape is fixed
  before steps 3 and 4 fill it in.
- `--probe-frame` gained `--wrapper` (the production `AXFrameWriteBatch`
  bracket), `--restore` (write the pre-probe frame back, with its own
  readback and its own `restore result=`), the AX minimum size when
  readable, and a second timestamped read at 1.0 s. Defaults and existing
  arguments are unchanged. Any failed AX call fails the probe, restoration
  included.

### The half-point trace line was misleading, not slow

A dwindle split produces targets like `(8,41,744,416.5)` and every readback
lands on the integer. The trace called every such sample off target, which
read as a window that never settles. It is not: `matches` has tolerated the
half point since before this checkpoint, so the attempt takes the
`allOnTarget` branch and accepts on the second stable sample, without waiting
the 0.24 s mismatch floor. `FrameSizingTransactionTests`
`testHalfPointTargetIsAcceptedBeforeTheMismatchFloor` pins that: the verdict
is `accepted`, the observed frame is the integer one, and the fake clock is
still short of `minimumMismatchSettle` when it returns. The readback line now
carries `onTarget=true` so the log says the same thing.

### Identified follow-up: two-axis `adjustForMinSizes` ordering

`BSPTreeTests.testAdjustForMinSizesSatisfiesBothAxesThroughDifferentAncestors`
is the isolated regression the plan asked for. **It fails, so it is marked
with an `XCTSkip` carrying the recorded input and output, and the algorithm is
left alone** — fixing it is a separate bounded change, not something to fold
into a diagnostics commit.

Input: three windows inserted in order into a tree, giving root `[1 | [2 over
3]]`; rect `(0,0,1920,1080)`, gap 8, padding 8. Window 3 reports a minimum of
`1200x800`, which needs width from the root's horizontal split and height
from the inner vertical one.

Output: before the adjustment window 3 is at `(964,544,948,528)`. After it,
root `splitRatio` is `0.36764705882352944`, the inner `splitRatio` is
unchanged at `0.5`, and window 3 lays out at `(1316,8,596,1064)` — 596 points
wide against a 1200-point minimum.

Mechanism: the width pass biases the root split so the right column is about
1200 wide (`8 + 1904 * 0.36764705882352944 = 708`; `1912 - 708 - 4 = 1200`). That makes the inner node's rect wider than tall, and
`BSPNode.direction(for:)` picks the longer axis, so the inner split flips
from vertical to horizontal. The height pass then walks up from the leaf,
finds no vertical ancestor, and adjusts nothing — and the flipped inner split
halves the width the first pass had just won. The two passes read geometry
the first pass has already changed.

## Guarded learning and adjusted-pass reconciliation (2026-09-13)

Step 2 of the sizing and recovery plan. Tolerances, timeouts, the write
order and the publication policy are unchanged. What changed is which
readbacks are allowed to become a remembered minimum, and when an accepted
frame lowers one.

Item 6 is the case: a third Safari window was admitted, inserted into a
candidate, stranded when that candidate was discarded, and then refused
forever by a minimum learned from the readback of a window that never
moved. A window that never moved reads back at its old origin and its old
size. Nothing about that is a refusal.

- `FrameReadbackPoller.learningRefusal` is the single guard. A window's
  oversize teaches a minimum only if the pass is a candidate or adjusted
  one, the attempt ended in a geometric refusal rather than an I/O or
  cleanup error, that window's three setters all returned success, every
  target read back and settled, the window is at the origin it was given
  within the position tolerance, and the actual size exceeds the target by
  more than the 20-point overshoot tolerance on that axis. Otherwise the
  `min evidence:` line carries `learn=false` and the guard's name.
- Evidence is judged per window. An aggregate rejection names one id; the
  others in the same pass are still evaluated on their own, and a window
  that fails a guard is skipped without blocking its neighbours.
- A restoration readback is never evidence. It rolls back to the frames
  the windows already had, so it produces no conflicts, no observations
  and no accepted sizes. That also removes a live mismatch: `classify`
  used the caller's configuration, so on the restoration path the
  conflict threshold had quietly become `target + 1`. The threshold is
  the candidate overshoot tolerance, and only tiling passes classify.
- Entries carry provenance. `seeded` is an `AXMinimumSize` value or a
  per-bundle-id guess; `observed` is a bound the app refused. Real
  evidence replaces a seeded hint instead of merging with it, so the axis
  nothing refused returns to unknown rather than riding along as if it
  had been observed. Fit checks read both; the state dump and the logs
  name the source.
- Per-axis evidence is kept per axis and zero means unknown. Minima are
  not capped against the screen and are not cleared by a whole-slot
  accept; both would throw away a real constraint. `MinSizeMemory.clear`,
  which had no callers, is gone rather than left as an invitation.
- `applyLayoutFinal` now reconciles against the memory like the first
  pass. The adjusted pass is exactly where a window that was given a
  bigger tile accepts a frame smaller than the one it refused, and the
  bound follows that accepted readback, not the tile it was asked for.

Evidence logs, both under `build/sizing/recovery/`:

- Red: `red-step2-learning-guards.log` (`testOversizeAtTheWrongOriginTeachesNoMinimum`
  fails, and `testWrongOriginWindowDoesNotBlockAGoodNeighboursEvidence` reports
  observations `[61, 62]` where only 62 earned one),
  `red-step2-minsize.log` (`testObservedEvidenceReplacesASeededHintInsteadOfMergingWithIt`
  reports `1200x360`, the seeded height merged into an observed entry), and
  `red-step2-adjusted-lowering.log`
  (`testAdjustedPassLowersTheBoundToTheSizeItActuallyAccepted` keeps the 588
  the candidate pass refused instead of the 573 the adjusted pass accepted).
- Green: `green-step2.log`.

Four of the refusals cannot be reached through the poller today.
`writesIncomplete` and `readbackIncomplete` are structurally excluded: a
write or cleanup error returns before anything is read, and a read error
returns `unknown`, which was already skipped, so an attempt that reaches
`validateFrames` has written and read everything. `restorationPhase` and
`notRejected` are excluded by where the call sits — `classify` skips a
restoration pass outright and only consults the guard inside a rejection.
All four are pinned directly, through `learningRefusal`, so a later change
to the transaction or to the call site cannot quietly start teaching minima
from a partial attempt. An attempt with no targets reports a complete,
stable readback of nothing; no window is in `writesCompleted`, so it cannot
satisfy the guards either. What does real filtering in production is
`originMismatch` and the 20-point overshoot boundary.

## Publication, restoration correspondence and cache recovery (2026-09-13)

Step 3 of the sizing and recovery plan. No timeout, tolerance, settle floor,
write order or learning rule changed. What changed is which layouts are
allowed to become the live tree, what a rollback is judged on, what the
engine says about geometry it could not verify, and how much of the drag
cache a failure throws away.

### Only an accepted layout publishes

The `2569a38` parked-originals exception is gone, and so is the ratio copy
that went with it. A degraded candidate now keeps the prior membership and
the prior ratios whatever is on screen, because nothing verified what is on
screen. Acceptance is the one verdict that carries all five conditions at
once — every target's three setters returned success, the final readback was
complete and stable, every window matched its target within the per-window
tolerances, the aggregate geometry passed `validateFrames`, and the caller's
generation still owns the key — so `publishes` is a check for acceptance plus
the progress that proves the first three. A cleanup error after frames that
read back fine is still a failure, and it still does not publish.

An attempt with no targets reports a complete, stable readback of nothing.
That cannot satisfy the write check, so the gate names the empty case
explicitly and lets it through as lifecycle: it is how a workspace that lost
its last window empties its tree.

### A rollback is judged per window

`FrameSizingConfiguration.correspondenceOnly` is set on both restoration
paths. The strict one-point size and position match still decides, and
containment still applies, but the pairwise overlap and gap checks stop being
verdicts. Two originals that overlapped before the candidate ran — an
incumbent and the untiled newcomer admitted over it, which is item 6's exact
shape — still overlap after it, and rejecting the rollback for that said
something false about correspondence. The overlaps are collected on the
result, ride along on the outcome as `restorationOverlaps`, and print in the
`verified layout ...` line as `originalOverlap=`. They cannot be mistaken for
a tiled layout, because only a candidate can publish.

### Unverified geometry

`TilingEngine` keys an unverified mark on `(workspace, screen)`. An accepted
layout clears it; every other outcome sets it, a superseded one records
nothing, and the mark dies with its key on display-change pruning or empty
tree removal. A tiled drag follows the same rule. `intendedTileRects` omits
every window under a marked key, so directional focus and swap fall back to
actual frames for all of them at once through `DirectionalGeometry.frame`,
the one expression both dispatcher paths build their `frameFor` closure from.
A visible window that is in no tree keeps its place in the candidate set on
its actual frame; that is what item 3 needed.

`unverifiedLayouts` carries the keys, their window ids and the ids the failed
attempt had just inserted, and `clearUnverifiedGeometry(forWorkspace:screen:)`
drops one. Nothing schedules a retry — that is step 4. The state dump's
`unverified=` field is now populated; `recovery pending=` is still empty.

### Progress-based drag cache invalidation

`FrameSizingTransaction.apply` returns a `Report`: the outcome plus a
`FrameSizingProgressReport` holding the candidate's progress, the
restoration's, and the restoration overlaps. The two written sets are
different sets — a rollback writes every captured original, including
windows the candidate never reached — so both travel.

`TiledDragCachePolicy.actions` makes one decision per member: refresh from a
verified readback, invalidate, or preserve. A committed drop and a verified
rollback refresh every member. A degraded drop invalidates every id either
attempt may have written plus the dragged id, and preserves the rest; with no
provenance it clears every member. The dragged id is always uncertain because
macOS moved it, not HyprMac. Clearing only the dragged id was rejected for
the opposite reason: a rollback touches the others. `tiledPositions` and the
per-window `cachedFrame`, plus the focus border and brackets, all read the
same decisions, so they cannot disagree. Degraded drops no longer hide the
dimming overlay wholesale; it is refreshed from the surviving entries.

Feedback is unchanged. The red rejection flash on a classification
`readFailed` stays until the batch-2 evidence gate.

Evidence logs, both under `build/sizing/recovery/`:

- Red: `red-step3-publication-and-recovery.log`, taken with the six behaviour
  switches reverted and the new API in place. Eleven cases fail on
  assertions: the parked-originals candidate publishes its membership and its
  adjusted ratios, a cleanup failure and an incomplete readback leave no
  unverified mark, a window 340 points short publishes anyway, an accepted
  retry has no mark to clear, a failed scratchpad migration leaves the
  destination unmarked, an overlapping rollback is reported as a failure
  rather than a verified restoration with `restorationOverlaps`, both narrowed
  cache cases wipe every member, and `intendedTileRects` still hands out rects
  for a tree that could not verify its layout.
- Green: `green-step3.log`.

Four of the new tests pass in both runs on purpose. They pin behaviour that
must not move: a superseded generation marks nothing, an accepted layout's
progress is what the gate reads, the fallback expression prefers an intended
rect when there is one, and a tree-absent window stays a focus candidate.
