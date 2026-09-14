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
