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
0.01 AX point. Position and size must each match within one AX point. The
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
