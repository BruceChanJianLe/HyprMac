# Stability audit, September 13, 2026

Baseline: `c5d0b74`, branch `audit/stability-hardening`. This is an audit of
mechanisms, followed by isolated regression fixes. Laptop behavior is not
verified by the hostless suite. Evidence line numbers refer to
`mailbox-audit-astra/evidence/06-since-install.txt`; source references below
refer to the baseline unless explicitly marked as final. No deployment belongs
to this audit. Messages drag feedback and the AX frame writer are out of scope.

## Findings before implementation

1. **High: recovery confuses tree insertion with new-window admission.**
   `TilingEngine.swift:1095,1199,1222` derives inserted IDs from absence in the
   current tree. A returned window whose old node was removed is inserted just
   like a new window. Evidence 19431–19443 explicitly reports 22524 returned
   in the same discovery batch as new 31766 and 31768; 19435–19581 subsequently
   recovers all three. The failure is not a guess about Safari minimum size.
   Fix direction: preserve admission identity separately from transient tree
   membership; returned incumbents must not become fallback targets.

2. **High: a later retile can route an already assigned window elsewhere.**
   `TilingEngine.swift:1104–1120` invokes `onAutoFloat` synchronously while
   constructing a candidate. `WindowManager.swift:372,2819–2854` assigns a new
   workspace and parks the window. Evidence 1922–1925 routes Outlook 27923
   from ws3 to ws4. This path survives alongside recovery's float-in-place
   policy. It also exposes candidate construction to callbacks that can change
   engine generation and ownership. Fix direction: return refusal as data and
   finish the assigned newcomer in place; keep count-based initial assignment
   separate from geometry recovery.

3. **High: oversize at the wrong origin triggers another visible write pass.**
   `FrameReadbackPoller.swift:174–184` appends conflicts before applying the
   evidence guards; `TilingEngine.swift:862–868` feeds them into adjustment.
   Learning correctly rejects a stale readback but layout still reacts to it.
   Fix: guard adjustment conflicts with the same completed-write, stable,
   target-origin evidence predicate. Preserve evidence for good neighbors.

4. **High: an adjusted layout is written even when it cannot satisfy the
   constraints just observed.** `TilingEngine.swift:862–868` does not check
   whether adjustment actually solved the conflict or even changed a target.
   Outlook evidence 797–883 shows two candidate passes plus restoration,
   repeated on recovery. The observed minimum needs nearly the whole built-in
   display. Fix: geometrically validate the proposed adjustment against the
   guarded per-axis constraints before sending setters. A known impossible
   adjustment should go straight to the existing restoration path.

5. **High: float-to-tile replaces an incumbent without asking for replacement.**
   `TilingEngine.swift:1922–1933` removes the deepest-right leaf after a failed
   fit; `FloatingWindowController.swift:119–136` adopts it into scratchpad.
   Evidence 1020 names the bumped incumbent. Fix: the toggle requests an
   available slot, with the existing explicit learned-minimum revalidation;
   no eviction as a side effect of tiling a floater.

6. **Medium: display notifications are consumed from an observer-order-dependent
   cache.** `DisplayManager.swift:27–30` independently refreshes on the same
   notification that `WindowManager.swift:2461–2469` uses for its early
   unchanged-fingerprint exit. Notification observer ordering is not an
   ownership contract. The fingerprint also excludes usable bounds and physical
   display identity (`WindowManager.swift:2537`). Evidence 247–320 has two
   built-in modes; gens 5, 6, 8 leave off-screen originals unrestored. Audit the
   settle callback and polling gate before selecting a fix; do not restore
   windows to disconnected screens or relax publication.

7. **Medium: unrelated actions cancel every pending admission.**
   `WindowManager.swift:1306,1945–1949` drops all recovery on focus and overlay
   actions. The visible nonfloating newcomer then has no owner until another
   retile, which can grant it a fresh retry. Fix direction: preserve unrelated
   work; use existing per-window move/float/close cleanup for targeted actions.

8. **Medium: two-axis ratio adjustment can change its own split axes.**
   `BSPTree.swift:366–380,399` recomputes direction after modifying an ancestor.
   The skipped regression documents `[1 | [2 over 3]]`, minimum 1200×800 in
   1920×1080, yielding only 596 px width. A safe bounded change must preserve
   the candidate's original split directions through ratio adjustment and
   still check feasibility. This is separate from the writer probe gate.

## Verification and limits

Baseline suite is running. Each implementation section below will record its
assertion-level red, full green suite, and remaining limits. Prior audits are
being checked against current source; their conclusions are not assumed.

## Fix 1: guarded adjustment evidence

Adjustment conflicts now pass the same evidence guard as learned minima.
The wrong-origin regression and mixed-neighbor regression fail with two
assertions before the change (`build/stability-audit/red-guard.log`). Full
suite after the fix (`green-guard.log`): `Executed 718 tests, with 201 tests
skipped and 0 failures`. Baseline had the same counts. This environment has
no live NSScreen; new geometry regressions will use synthetic screens.

## Fix 2: retain verified incumbent identity

The engine now remembers verified admissions by workspace independently of BSP
nodes. Hiding or migrating a window preserves that identity; final lifecycle
forgetting removes it. Returning incumbents remain visible in the unverified
geometry record, but are excluded from recovery targets. The synthetic-screen
regression reproduces successful tile → gone-node removal → returned incumbent
plus newcomer → failed candidate. Before the fix it reports both IDs; after it
only the newcomer is stranded. `red-identity.log`: 1 assertion failure.
`green-identity.log`: `Executed 719 tests, with 201 tests skipped and 0 failures`.
This protects previously verified incumbents, not windows that have never had
an accepted admission. It does not suppress legitimate minimize/unhide retiles.

Git commits are blocked: the session's filesystem profile makes resolved
worktree metadata read-only. `git add` and `git commit` both fail creating
`/Users/zgray/GitHub/HyprMac/.git/worktrees/stability-hardening/index.lock`.
No alternate checkout or permission bypass is used. Numbered patches under
`build/stability-audit/` preserve independently reviewable implementation units;
they are not commit hashes.

## Fix 3: assigned fit refusals stay in place

Membership construction returns no-fit IDs as data and invokes no overflow
callback. The WindowManager router and its scratchpad fallback wiring are
removed. The bounded recovery recognizes a preflight refusal as already judged:
it checks current ownership/readability at the scheduled turn and floats in
place without another sizing attempt. Count-based initial assignment is intact.
`red-routing.log` has two failed assertions for callback routing and lost refusal
identity; `red-routing-recovery.log` adds the retry assertion. Its synthetic
screen initially collided with the alternate screen's identity; distinct fake
geometries correct that test setup. The old routing expectations are updated.
Full suite for fix 3 (`green-routing.log`): `Executed 721 tests, with 166 tests
skipped and 0 failures`. Recovery's injected state-machine tests now run without
requiring a live screen. Fake NSScreen equality uses instance identity; AppKit's
empty device metadata otherwise made two synthetic screens compare equal.

## Fix 4: skip impossible adjusted writes

The proposed adjusted frames must accommodate the guarded refused axes within
the existing candidate size allowance before any adjusted setter runs. An
unsolved conflict goes directly to restoration. Actual acceptance still uses
complete readback and the unchanged aggregate safety rules. The synthetic
regression observes 18 setters before the fix, versus at most 12 afterward
(two windows, candidate plus restoration). `red-adjustment.log`: 1 failure.
`green-adjustment.log`: `Executed 722 tests, with 166 tests skipped and 0 failures`.
Unknown minima can still require the first candidate and one bounded recovery;
this removes futile adjustment, not the evidence-gathering attempt.

## Fix 5: float-to-tile does not evict

A force insertion now returns `noFittingSlot` before writing if no leaf takes
the window. The eviction result and scratchpad adoption callback are removed.
Explicit learned-minimum revalidation remains available and still obeys depth.
Two red cases contain five failed assertions for replaced IDs and changed tree
structure (`red-eviction.log`). The actual-layout-refusal test now uses depth 2
so it continues to exercise I/O failure rather than being stopped by capacity.
Full suite (`green-eviction.log`): `Executed 722 tests, with 155 tests skipped and
0 failures`. All 11 force-insertion tests now run with synthetic fallback screens.

## Fix 6: compare fresh display snapshots

Every fingerprint comparison refreshes from the screen provider, including the
notification's early-exit check and the delayed settle sample. The signature
includes physical display ID and visible bounds, so a changed usable frame is
not ignored. This removes reliance on notification observer order. Two injected
provider regressions fail four assertions against the old cached signature;
the provider seam and old signature were extracted before that red run.
The eleven-second transient mode in the log can still outlast the unchanged
2-second debounce. This fix does not claim that every intermediate macOS mode
can be identified before macOS announces the final one.
Full suite for fix 6 (`green-display.log`): `Executed 724 tests, with 155 tests
skipped and 0 failures`.

## Fix 7: focus actions preserve pending admissions

Directional focus, floating focus, menu focus, keybind display, and app launch
no longer cancel admission recovery. Workspace reveal already preserved it.
Membership-changing actions retain the existing cancellation rule. Five
assertions fail before the change (`red-focus-action.log`). The full suite
result is recorded in `green-focus-action.log`. Targeted cancellation for
unrelated membership actions remains a narrower follow-up; this change closes
the ordinary focus-key interruption without changing geometry ownership.
Full suite for fix 7: `Executed 725 tests, with 155 tests skipped and 0 failures`.

## Fix 8: restore incumbents before admitting newcomers

The verified-admission history also orders a rebuild: returned incumbents get
first choice of slots before frame/ID sorting of new arrivals. Without this,
a lower-ID newcomer can take the empty root and a known large returning
incumbent is refused, even though recovery correctly excludes that incumbent.
The new red case fails both membership and refusal assertions. The membership
fixture now injects its screen into DisplayManager and runs all 48 cases with
no display skips. That uncovered one old ordinary-refusal expectation missed
in fix 3; it now expects the returned refusal ID. `red-return-priority.log`
records all three failures, distinguishing those two causes.
Full suite for fix 8 (`green-return-priority.log`): `Executed 726 tests, with
111 tests skipped and 0 failures`.

## Fix 9: a same-home display change invalidates active sizing

`handleDisplayChange` previously advanced the layout generation only when a
tree migrated or became orphaned. A resolution/usable-bounds change at the
same origin could therefore let an active candidate publish stale geometry.
Every real reconcile now invalidates sizing, even when all keys keep their
homes. A reentrant same-home display callback during setters fails two
assertions before the fix (`red-display-generation.log`); afterward it reports
superseded, retains the old tree, and does not restore over the new operation.
Full suite for fix 9 (`green-display-generation.log`): `Executed 727 tests, with
111 tests skipped and 0 failures`.

## Fix 10: do not publish a subset that omits a returning incumbent

When two verified incumbents return with constraints that no longer fit, one
could be omitted while the other alone published. Recovery must not float that
incumbent, but it must not disappear from geometry tracking either. A refused
incumbent now stops the candidate before any setters, preserves the prior tree,
and marks every affected window unverified. The new `noFittingSlot(id)` failure
is structural; it never teaches a minimum. The frame writer is unchanged.
The red test has four failures (`red-returned-refusal.log`): publication, writes,
missing unverified IDs, and stale intended geometry. The final behavior requires
a later successful layout or a user decision to float/move a window; it does
not pretend incompatible incumbents form a valid layout.
Full suite for fix 10 (`green-returned-refusal.log`): `Executed 728 tests, with
111 tests skipped and 0 failures`.

## Wider audit and prior-work comparison

| Earlier fix or concern | Current source and disposition |
| --- | --- |
| Destroy notification PID fallback | Present, `AXNotificationService.swift:225–242`. |
| Initial window subscriptions | Present, `WindowManager.swift:456–469`, notification service `34–41`. |
| Mass-gone short rechecks | Present, discovery `168–175`, WindowManager `2248–2254`. |
| Stale scheduled poll closures | Present, `PollingScheduler.swift:70–115`, generation checked after stop. |
| Retry unsuccessful destroy subscriptions | Present, notification service `155–170`. |
| Scratchpad tiled default and saved preference | Present, `UserConfigDefaults.swift:42–44`, `ScratchpadController.swift:319–350`. |
| Deterministic startup/Retile All packing | Present, `RetileAllPlanner.swift:22–56,98–129`, WindowManager `1671–1707`. Current capacity is `1 << depth`, not the earlier audit's count. |
| Disabled border cleanup | Present for ordinary chrome. `FocusBorder.swift:56,366–368` deliberately permits rejection feedback while disabled. This later behavior conflicts with the earlier audit but is not ported back: tonight's instruction explicitly preserves Messages drag feedback. |
| Publish only verified geometry, correspondence restoration, per-key fallback geometry | Present and retained. The older audit's degraded-publication objections were addressed by the seven reviewed commits. No tolerance, writer ordering, or timeout is changed here. |

The prior feature worktree's dirty files are a development snapshot. The
comparison above follows current mechanisms rather than copying that snapshot.

## Deferred findings and why

- **Display modes can remain transient longer than the debounce.** Evidence
  247–320 shows 1920×1080 accepted before 1512×982 arrives about eleven seconds
  later. Fresh snapshots and same-home generation invalidation fix two concrete
  races. They do not prove a screen is in its final mode. A safe display-specific
  baseline/fitting policy still needs laptop evidence; adding an arbitrary longer
  wait or restoring off-screen originals would trade one glitch for another.
- **Reconcile drops its transition flag before the final workflow.** Baseline
  `WindowManager.swift:2525–2531` clears it before migration, AX enumeration,
  parking, and tiling. Removing the synchronous overflow callback closes the
  confirmed nested route. A complete reentrancy guard around all display and
  focus callbacks remains unimplemented; it needs an injected orchestration
  integration test, not just a Boolean predicate test.
- **Transient window churn remains.** Discovery `235–260` treats an omission as
  hidden immediately; dispatcher `143–170` removes and retiles it. The evidence
  at 19703–19983 includes windows that actually disappear shortly after opening.
  Incumbent identity is now protected, but preserving every reserved hidden BSP
  leaf would also stop intended expansion on Cmd-H/minimize. A confirmed-absence
  policy must distinguish genuine hides from incomplete AX snapshots first.
- **Two-axis ratio adjustment remains skipped.** The 1200×800 regression still
  exposes axis flipping (`BSPTree.swift:366–399`). Fix 4 avoids writing an
  adjustment that leaves its observed constraints unsatisfied. A full fix needs
  direction state that survives verified publication while preserving manual
  overrides and resetting correctly on later membership changes. It is not
  silently folded into a frame-write change.
- **Delayed focus can still be stale.** `HyprWindow.swift:274–303` reasserts focus
  50 ms after activation without a current-intent token. Floating controller
  `286–303` restores captured focus after 20 ms. WindowManager's post-drag
  `916–924` and Hypr-release `1068–1092` callbacks can redraw an old border.
  A common focus-intent/click generation is needed: checking only cached last
  focus would still miss a native click that has not been reconciled. No claim
  of fixing these callbacks is made.
- **Visible move rollback can degrade.** Source ownership remains while the
  mover can remain on the destination screen. A later poll can interpret it as
  drift. The existing restoration reach handles the ordinary case; failed AX
  restoration still needs explicit move-recovery ownership. This is unverified
  on two physical displays in this session.
- **Discovery reservations and subscription lifetime retain prior residuals.**
  Destroy rechecks are keyed by PID and bounded; an early successful omission
  can release a real window's reservation; unresolved reservations can survive
  exhausted read retries; window subscription IDs persist until app detach.
  No supplied evidence isolates one of these as tonight's root cause.
- **Timing knobs remain unchanged.** All 298 logged frame attempts were accepted
  (253) or geometrically rejected (45). There are no `deadlineExceeded` or
  `cleanupFailed` occurrences; maximum logged attempt elapsed time is 272 ms.
  This log does not justify raising the 360 ms deadline or 100 ms per-call
  timeout. Synchronous AX under load and unbounded asynchronous file-log backlog
  remain broader risks, not measured failures here.

## Required laptop checks after a separately authorized deployment

1. On the built-in screen, open Outlook beside a tile. Check the window stays
   assigned to the same workspace and eventually floats. A known no-fit should
   have no newcomer setters; a first unknown minimum may still need a candidate,
   restoration, and one recovery attempt. Look for the skipped-adjustment log.
2. Start with one tiled Safari. Hide/unhide it while opening another window;
   repeat after closing transient Start Page windows. The original must never
   appear in recovery fallback IDs. Test both window creation and return order.
3. Fill a workspace to its configured depth. Float-to-tile a separate window.
   It must stay floating on refusal, with no incumbent entering scratchpad.
4. Press focus arrows or show keybinds during a pending admission. Recovery must
   finish once; focus actions must not erase it and grant a later fresh retry.
5. Undock with four tiled windows, wait through both reported display modes,
   and redock. Save state dumps plus candidate/adjusted/restoration logs. Check
   assignments, unverified IDs, visibility, and directional focus. This is still
   a required acceptance gate; the full undock defect is not claimed solved.
6. Keep the existing docked Terminal probe gate: compare wrapper/order and
   delayed reads from a saved baseline before changing the writer. Include a
   portrait top/bottom split at gap 8. Messages drag feedback is unchanged.

## Fix 11: explicit departure ends incumbent protection

Final review found that remembered admission must distinguish a temporary hide
from an explicit departure. `removeWindow(_:fromWorkspace:)`, used by moves,
float toggles, and scratchpad sends, now ends that workspace's protection;
`removeWindowID`, used by discovery disappearance, preserves it. The red
regression successfully tiles a window, explicitly removes it, then refuses its
later readmission. Before the reset it loses its recovery target; afterward it
is a newcomer again. `red-explicit-departure.log`: 1 failure. This unit also
removes the now-unused overflow callback API and corrects its stale comments
and test expectations. The signed build and two full runs made before this
review are superseded by the final runs below.
Full suite for fix 11 (`green-explicit-departure.log`): `Executed 729 tests, with
111 tests skipped and 0 failures`.

## Fix 12: usable-frame noise does not restart display reconciliation

Review caught a regression in fix 6's exact usable-bounds signature. A one-point
Dock/menu-bar variation would now hide scratchpad and trigger a full reconcile.
The signature keeps a stable per-display bounds anchor and ignores edge changes
within the existing one-point rect comparison slack. It does not move that
anchor on noise, so successive one-point shifts cannot accumulate invisibly.
Physical identity, frame changes, and larger usable-area changes still alter
the signature. Actual layout geometry and every frame-validation tolerance are
unchanged. `red-display-noise.log`: 1 failure for the one-point case; the same
test also asserts a two-point accumulated change is detected.
