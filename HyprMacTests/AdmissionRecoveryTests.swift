import XCTest
import Cocoa
@testable import HyprMac

// the bounded admission recovery: one retry through an injected scheduler,
// then an explicit float in place. every context check and every
// cancellation case is driven through the seams, so no wall clock and no
// live AX are involved.

final class AdmissionRecoveryTests: XCTestCase {

    private var screen: NSScreen!
    private var other: NSScreen!
    private var recovery: AdmissionRecovery!
    private var harness: RecoveryHarness!

    override func setUpWithError() throws {
        guard let main = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("requires display geometry")
        }
        screen = main
        other = OtherRecoveryScreen()
        recovery = AdmissionRecovery()
        harness = RecoveryHarness(screen: screen)
        harness.install(on: recovery)
    }

    private func failedAdmission(_ ids: Set<CGWindowID>, workspace: Int = 2,
                                 published: Set<CGWindowID> = [11],
                                 generation: UInt64 = 7,
                                 failure: FrameSizingFailure? = .geometryMismatch(11),
                                 restored: Set<CGWindowID> = [11],
                                 refused: Set<CGWindowID> = []) -> TilingEngine.AdmissionResult {
        TilingEngine.AdmissionResult(workspace: workspace, screen: screen, generation: generation,
                                     insertedIDs: ids, publishedIDs: published,
                                     failure: failure, restoredIDs: restored, refusedIDs: refused)
    }

    // MARK: - the identity of the newcomer

    func testStrandedNewcomerIsTrackedNotTheWindowTheFailureNamed() {
        // the failure names 11, an incumbent that refused its frame; 26 is
        // the window that was new
        recovery.note(failedAdmission([26]))
        XCTAssertEqual(recovery.pendingWindowIDs, [26])
    }

    func testAcceptedAdmissionTracksNothing() {
        recovery.note(TilingEngine.AdmissionResult(
            workspace: 2, screen: screen, generation: 7, insertedIDs: [26],
            publishedIDs: [11, 26], failure: nil, restoredIDs: [], refusedIDs: []))
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        XCTAssertEqual(harness.scheduled.count, 0)
    }

    func testAWindowABypassedPassRefusedOutrightIsStrandedToo() {
        // nothing routed it: routing inside a bypassed pass would pick its
        // next workspace with the very bounds that pass is ignoring
        recovery.note(failedAdmission([], published: [11], failure: nil, restored: [],
                                      refused: [26]))
        XCTAssertEqual(recovery.pendingWindowIDs, [26])
        XCTAssertEqual(harness.scheduled.count, 1)
    }

    // MARK: - which key presses cancel

    func testShowingAnotherWorkspaceDoesNotCancelAPendingRetry() {
        XCTAssertFalse(WindowManager.cancelsPendingRecovery(.switchWorkspace(3)))
        XCTAssertFalse(WindowManager.cancelsPendingRecovery(.cycleWorkspace(1)))
    }

    func testEveryOtherActionCancelsAPendingRetry() {
        XCTAssertTrue(WindowManager.cancelsPendingRecovery(.moveToWorkspace(3)))
        XCTAssertTrue(WindowManager.cancelsPendingRecovery(.toggleFloating))
    }

    // MARK: - the one retry

    func testSuccessfulRetryTilesTheNewcomerAndClearsPending() throws {
        harness.place = [26]
        recovery.note(failedAdmission([26]))
        XCTAssertEqual(recovery.phase(of: 26), .awaitingRetry)

        harness.fire()

        XCTAssertEqual(harness.attempts.count, 1)
        XCTAssertEqual(try XCTUnwrap(harness.attempts.first).newcomers, [26])
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        XCTAssertTrue(harness.floated.isEmpty)
        XCTAssertTrue(harness.clearedUnverified.isEmpty)
    }

    func testRetryRunsAtTheConfiguredDelay() {
        recovery.retryDelay = 0.25
        recovery.note(failedAdmission([26]))
        XCTAssertEqual(harness.scheduled.map(\.delay), [0.25])
    }

    func testRetryBypassesTheMinimaObservedSinceTheAdmissionStarted() throws {
        recovery.note(failedAdmission([26], generation: 42))
        harness.fire()
        let attempt = try XCTUnwrap(harness.attempts.first)
        XCTAssertEqual(attempt.bypass, [26: 42])
    }

    func testEachNewcomerBypassesOnlyBackToItsOwnAdmission() throws {
        recovery.note(failedAdmission([26], generation: 40))
        // a later pass strands 27 while 26 is still pending and still not in
        // the published tree
        recovery.note(failedAdmission([27], generation: 55))
        harness.fire()

        // both are retried together and neither inherits the other's reach
        XCTAssertEqual(try XCTUnwrap(harness.attempts.first).bypass, [26: 40, 27: 55])
    }

    // MARK: - final policy

    func testRepeatedGeometryFailureFloatsTheNewcomerInPlace() {
        harness.failure = .geometryMismatch(11)
        recovery.note(failedAdmission([26], failure: .geometryMismatch(11)))
        harness.fire()

        XCTAssertEqual(harness.floated.map(\.id), [26])
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
    }

    func testRepeatedIOFailureFloatsTheNewcomerInPlace() {
        harness.failure = .readFailed(26, .cannotComplete)
        recovery.note(failedAdmission([26], failure: .writeFailed(11, .cannotComplete)))
        harness.fire()

        XCTAssertEqual(harness.floated.map(\.id), [26])
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
    }

    func testTheFallbackAsksTheEngineToClearTheMark() {
        recovery.note(failedAdmission([26]))
        harness.fire()
        // whether it actually clears is the engine's call — it saw every
        // attempt that marked the key, and this recovery saw two of them.
        // TilingEngineMembershipTransactionTests pins the refusal.
        XCTAssertEqual(harness.clearedUnverified.map(\.workspace), [2])
    }

    func testTheFallbackDoesNothingBesidesAttemptFloatAndClear() {
        recovery.note(failedAdmission([26]))
        harness.fire()

        XCTAssertEqual(harness.calls, ["attempt", "floatInPlace", "clearUnverified"],
                       "no routing, no workspace move, no second attempt")
    }

    func testTheRetryCannotReArmItself() {
        recovery.note(failedAdmission([26]))
        harness.fire()
        XCTAssertEqual(harness.scheduled.count, 1)
        XCTAssertEqual(harness.attempts.count, 1)
    }

    func testASecondFailedAdmissionForAPendingWindowDoesNotGiveItAnotherRetry() {
        recovery.note(failedAdmission([26]))
        recovery.note(failedAdmission([26]))
        XCTAssertEqual(harness.scheduled.count, 1)
    }

    // MARK: - multiple newcomers

    func testOneFailingNewcomerDoesNotFloatTheOthers() throws {
        harness.place = [26]
        recovery.note(failedAdmission([26, 27], published: [11]))
        XCTAssertEqual(recovery.pendingWindowIDs, [26, 27])

        harness.fire()

        XCTAssertEqual(try XCTUnwrap(harness.attempts.first).newcomers, [26, 27])
        XCTAssertEqual(harness.floated.map(\.id), [27])
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
    }

    // MARK: - unreadable newcomer

    func testUnreadableNewcomerStaysPendingWithNoSecondTimer() {
        harness.readable.remove(26)
        recovery.note(failedAdmission([26]))
        harness.fire()

        XCTAssertEqual(recovery.pendingWindowIDs, [26])
        XCTAssertEqual(recovery.phase(of: 26), .awaitingEvidence)
        XCTAssertEqual(harness.scheduled.count, 1, "no renewed timer")
        XCTAssertTrue(harness.attempts.isEmpty, "nothing is attempted on a window we cannot read")
        XCTAssertTrue(harness.floated.isEmpty, "no frame is invented for it")
    }

    func testEvidenceGivesAnUnreadableNewcomerItsOneAttempt() {
        harness.readable.remove(26)
        recovery.note(failedAdmission([26]))
        harness.fire()

        harness.readable.insert(26)
        harness.place = [26]
        recovery.noteEvidence(for: 26)

        XCTAssertEqual(harness.attempts.count, 1)
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        XCTAssertEqual(harness.scheduled.count, 1, "evidence is not a new timer")
    }

    func testEvidenceOnAStillUnreadableNewcomerChangesNothing() {
        harness.readable.remove(26)
        recovery.note(failedAdmission([26]))
        harness.fire()
        recovery.noteEvidence(for: 26)
        recovery.noteEvidence(for: 26)

        XCTAssertEqual(recovery.pendingWindowIDs, [26])
        XCTAssertTrue(harness.attempts.isEmpty)
        XCTAssertEqual(harness.scheduled.count, 1)
    }

    // MARK: - hidden workspace

    func testHiddenWorkspaceRevealGivesOneAttemptThenTheSamePolicy() {
        harness.visibleWorkspaces = []
        recovery.note(failedAdmission([26]))
        harness.fire()
        XCTAssertEqual(recovery.phase(of: 26), .awaitingEvidence)
        XCTAssertTrue(harness.attempts.isEmpty)

        harness.visibleWorkspaces = [2]
        recovery.noteEvidence(for: 26)

        XCTAssertEqual(harness.attempts.count, 1)
        XCTAssertEqual(harness.floated.map(\.id), [26])
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
    }

    // MARK: - scratchpad

    func testScratchpadAdmissionIsNeverTracked() {
        recovery.note(failedAdmission([26], workspace: TilingEngine.scratchpadWorkspace))
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        XCTAssertTrue(harness.scheduled.isEmpty)
    }

    // MARK: - cancellation

    func testACloseCancelsTheRetry() {
        recovery.note(failedAdmission([26]))
        harness.alive.remove(26)
        recovery.forget(26)
        harness.fire()

        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        XCTAssertTrue(harness.attempts.isEmpty)
    }

    func testAVanishedWindowIsDroppedWhenTheRetryFires() {
        recovery.note(failedAdmission([26]))
        harness.alive.remove(26)
        harness.fire()

        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        XCTAssertTrue(harness.attempts.isEmpty)
        XCTAssertTrue(harness.floated.isEmpty)
    }

    func testStopCancelsTheRetry() {
        recovery.note(failedAdmission([26]))
        recovery.cancelAll(reason: "stop")
        harness.fire()
        XCTAssertTrue(harness.attempts.isEmpty)
    }

    func testALaterPressCancelsTheRetry() {
        recovery.note(failedAdmission([26]))
        recovery.cancelAll(reason: "later press")
        harness.fire()
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        XCTAssertTrue(harness.attempts.isEmpty)
    }

    func testAPendingDisplayTransitionHoldsTheRetryInsteadOfTilingMidReconfigure() {
        harness.displayTransitionPending = true
        recovery.note(failedAdmission([26]))
        harness.fire()

        XCTAssertTrue(harness.attempts.isEmpty, "nothing is tiled while the screens are moving")
        XCTAssertEqual(recovery.phase(of: 26), .awaitingEvidence)
        XCTAssertEqual(harness.scheduled.count, 1, "and no new timer")
    }

    func testADisplayChangeCancelsTheRetry() {
        recovery.note(failedAdmission([26]))
        recovery.cancelAll(reason: "display change")
        harness.fire()
        XCTAssertTrue(harness.attempts.isEmpty)
    }

    func testAUserFloatCancelsTheRetry() {
        recovery.note(failedAdmission([26]))
        harness.floatingIDs.insert(26)
        harness.fire()

        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        XCTAssertTrue(harness.attempts.isEmpty)
        XCTAssertTrue(harness.floated.isEmpty, "the user already floated it")
    }

    func testAWorkspaceMoveCancelsTheRetry() {
        recovery.note(failedAdmission([26]))
        harness.workspaces[26] = 3
        harness.fire()
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        XCTAssertTrue(harness.attempts.isEmpty)
    }

    func testAScreenChangeCancelsTheRetry() {
        recovery.note(failedAdmission([26]))
        harness.homeScreen = other
        harness.fire()
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        XCTAssertTrue(harness.attempts.isEmpty)
    }

    func testANewerLayoutThatTilesTheNewcomerResolvesIt() {
        recovery.note(failedAdmission([26]))
        recovery.note(TilingEngine.AdmissionResult(
            workspace: 2, screen: screen, generation: 9, insertedIDs: [],
            publishedIDs: [11, 26], failure: nil, restoredIDs: [], refusedIDs: []))

        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        harness.fire()
        XCTAssertTrue(harness.attempts.isEmpty)
    }

    func testCancellingOneWindowLeavesTheOtherItsRetry() throws {
        recovery.note(failedAdmission([26, 27], published: [11]))
        recovery.cancel(26, reason: "user floated it")
        harness.place = [27]
        harness.fire()

        XCTAssertEqual(harness.attempts.count, 1)
        XCTAssertEqual(try XCTUnwrap(harness.attempts.first).newcomers, [27])
    }

    // MARK: - click focus ordering

    func testAClickPrefersARecoveryNewcomerOverTheTiledIncumbentUnderIt() {
        let overlap = CGRect(x: 100, y: 100, width: 400, height: 300)
        let target = WindowManager.clickFocusTarget(
            at: CGPoint(x: 200, y: 200),
            overlayFrames: [(id: 26, frame: overlap)],
            tiledPositions: [11: CGRect(x: 0, y: 0, width: 800, height: 600)])

        XCTAssertEqual(target?.id, 26)
        XCTAssertEqual(target?.reason, "syncTracker-floating")
    }

    func testARecoveryNewcomerSaysSoInsteadOfClaimingToBeFloating() {
        let overlap = CGRect(x: 100, y: 100, width: 400, height: 300)
        let target = WindowManager.clickFocusTarget(
            at: CGPoint(x: 200, y: 200),
            overlayFrames: [(id: 26, frame: overlap)],
            tiledPositions: [11: CGRect(x: 0, y: 0, width: 800, height: 600)],
            recoveryIDs: [26])

        XCTAssertEqual(target?.id, 26)
        XCTAssertEqual(target?.reason, "syncTracker-recovery",
                       "it is in no tree and not floating either; the log should not say floating")
    }

    func testAClickOutsideEveryOverlayStillPicksTheTile() {
        let target = WindowManager.clickFocusTarget(
            at: CGPoint(x: 20, y: 20),
            overlayFrames: [(id: 26, frame: CGRect(x: 100, y: 100, width: 400, height: 300))],
            tiledPositions: [11: CGRect(x: 0, y: 0, width: 800, height: 600)])

        XCTAssertEqual(target?.id, 11)
        XCTAssertEqual(target?.reason, "syncTracker-tiled")
    }
}

/// Drives every seam `AdmissionRecovery` has, and records what it asked for.
private final class RecoveryHarness {
    struct Attempt {
        let workspace: Int
        let bypass: [CGWindowID: UInt64]
        var newcomers: Set<CGWindowID> { Set(bypass.keys) }
    }

    let screen: NSScreen
    var homeScreen: NSScreen
    var visibleWorkspaces: Set<Int> = [2]
    var workspaces: [CGWindowID: Int] = [26: 2, 27: 2, 11: 2]
    var floatingIDs: Set<CGWindowID> = []
    var alive: Set<CGWindowID> = [11, 26, 27]
    var readable: Set<CGWindowID> = [11, 26, 27]

    /// ids the next attempt manages to tile
    var place: Set<CGWindowID> = []
    var failure: FrameSizingFailure? = .geometryMismatch(11)
    var displayTransitionPending = false

    private(set) var scheduled: [(delay: TimeInterval, body: () -> Void)] = []
    private(set) var attempts: [Attempt] = []
    private(set) var floated: [(id: CGWindowID, reason: String)] = []
    private(set) var clearedUnverified: [(workspace: Int, screen: NSScreen)] = []
    /// every action seam the recovery invoked, in order
    private(set) var calls: [String] = []
    private var windows: [CGWindowID: HyprWindow] = [:]

    init(screen: NSScreen) {
        self.screen = screen
        self.homeScreen = screen
        for id in [CGWindowID(11), 26, 27] { windows[id] = makeWindow(id: id) }
    }

    func install(on recovery: AdmissionRecovery) {
        recovery.schedule = { [weak self] delay, body in self?.scheduled.append((delay, body)) }
        recovery.workspaceFor = { [weak self] id in self?.workspaces[id] }
        recovery.homeScreenForWorkspace = { [weak self] _ in self?.homeScreen }
        recovery.isWorkspaceVisible = { [weak self] ws in self?.visibleWorkspaces.contains(ws) ?? false }
        recovery.isFloating = { [weak self] id in self?.floatingIDs.contains(id) ?? false }
        recovery.liveWindow = { [weak self] id in
            guard let self, self.alive.contains(id) else { return nil }
            return self.windows[id]
        }
        recovery.isReadable = { [weak self] window in
            self?.readable.contains(window.windowID) ?? false
        }
        recovery.isDisplayTransitionPending = { [weak self] in
            self?.displayTransitionPending ?? false
        }
        recovery.attempt = { [weak self] workspace, _, bypass in
            guard let self else { return AdmissionRecovery.AttemptResult() }
            self.calls.append("attempt")
            self.attempts.append(Attempt(workspace: workspace, bypass: bypass))
            return AdmissionRecovery.AttemptResult(placed: self.place, failure: self.failure)
        }
        recovery.floatInPlace = { [weak self] window, reason in
            self?.calls.append("floatInPlace")
            self?.floated.append((window.windowID, reason))
        }
        recovery.clearUnverified = { [weak self] workspace, screen in
            self?.calls.append("clearUnverified")
            self?.clearedUnverified.append((workspace, screen))
        }
    }

    /// Run every timer armed so far, once.
    func fire() {
        let pending = scheduled
        for entry in pending { entry.body() }
    }
}

private final class OtherRecoveryScreen: NSScreen {
    override var frame: NSRect { NSRect(x: 5000, y: 0, width: 1200, height: 900) }
    override var visibleFrame: NSRect { frame }
}

/// The two places a window ends up floating without the user asking: the
/// recovery fallback, and a float→tile the tree refused. Both must leave the
/// controller's set and the window's own flag saying the same thing.
final class FloatingFlagConsistencyTests: XCTestCase {

    private var stateCache: WindowStateCache!
    private var displayManager: DisplayManager!
    private var workspaceManager: WorkspaceManager!
    private var tilingEngine: TilingEngine!
    private var controller: FloatingWindowController!
    private var screen: NSScreen!
    private var workspace: Int!

    override func setUpWithError() throws {
        displayManager = DisplayManager()
        guard let primary = displayManager.screens.first else {
            throw XCTSkip("no NSScreen available — test requires a display")
        }
        screen = primary
        stateCache = WindowStateCache()
        workspaceManager = WorkspaceManager(displayManager: displayManager)
        tilingEngine = TilingEngine(displayManager: displayManager,
                                    frameSizingIOFactory: acceptingFrameSizingIOFactory())
        let focusBorder = FocusBorder()
        controller = FloatingWindowController(
            stateCache: stateCache,
            suppressions: SuppressionRegistry(),
            workspaceManager: workspaceManager,
            tilingEngine: tilingEngine,
            displayManager: displayManager,
            accessibility: AccessibilityManager(),
            cursorManager: CursorManager(),
            focusController: FocusStateController(focusBorder: focusBorder),
            focusBorder: focusBorder,
            dimmingOverlay: DimmingOverlay()
        )
        controller.animatedRetile = { body in body() }
        workspace = workspaceManager.workspaceForScreen(screen)
    }

    func testFloatInPlaceSetsBothFlags() {
        let window = makeWindow(id: 771)
        XCTAssertFalse(window.isFloating)

        controller.floatInPlace(window, reason: "admission recovery")

        XCTAssertTrue(stateCache.floatingWindowIDs.contains(771))
        XCTAssertTrue(window.isFloating)
        XCTAssertNotNil(stateCache.cachedWindows[771])
    }

    func testARefusedFloatToTileLeavesTheWindowFloatingAndFlashes() throws {
        try XCTSkipIf(workspaceManager.isMonitorDisabled(screen), "monitor is disabled here")
        // maxDepth 1 fills at two leaves, so a third window has to evict —
        // and this one will not fit even the emptied slot
        tilingEngine.maxSplitsPerMonitor[screen.localizedName] = 1
        for id in [CGWindowID(781), 782] {
            XCTAssertEqual(tilingEngine.forceInsertWindow(makeWindow(id: id),
                                                          toWorkspace: workspace, on: screen),
                           .inserted)
        }

        let refused = makeWindow(id: 783)
        refused.observedMinSize = CGSize(width: 100_000, height: 100_000)
        refused.isFloating = true
        stateCache.floatingWindowIDs.insert(refused.windowID)
        var flashed: [CGWindowID] = []
        controller.rejectFloatToTile = { flashed.append($0.windowID) }

        controller.toggle(refused, on: screen, in: workspace)

        XCTAssertTrue(stateCache.floatingWindowIDs.contains(783), "still a floater")
        XCTAssertTrue(refused.isFloating, "and its own flag agrees")
        XCTAssertEqual(flashed, [783])
        XCTAssertEqual(Set(tilingEngine.windowIDs(inTreeForWorkspace: workspace, screen: screen)),
                       [781, 782], "the tree the refusal left alone, eviction included")
    }
}
