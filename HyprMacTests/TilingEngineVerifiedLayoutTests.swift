import Cocoa
import XCTest
@testable import HyprMac

final class TilingEngineVerifiedLayoutTests: XCTestCase {
    func testCellQuantizedWindowTilesWithoutRestoringSiblings() {
        let first = makeWindow(id: 501)
        let second = makeWindow(id: 502)
        let tree = BSPTree()
        XCTAssertTrue(tree.insert(first, maxDepth: 3))
        XCTAssertTrue(tree.insert(second, maxDepth: 3))

        let usable = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let originals: [CGWindowID: CGRect] = [
            501: CGRect(x: 40, y: 40, width: 440, height: 620),
            502: CGRect(x: 520, y: 40, width: 440, height: 620)
        ]
        let trace = QuantizingSizingTrace(frames: originals, quantizedWindowID: 501)
        let engine = TilingEngine(
            displayManager: DisplayManager(),
            frameSizingIOFactory: { _, generation in trace.io(generation: generation) }
        )

        let generation = engine.beginLayoutGeneration()
        let outcome = engine.applyVerifiedLayout(tree, in: usable, generation: generation)

        guard case let .accepted(actualFrames, _) = outcome else {
            return XCTFail("expected accepted quantized layout, got \(outcome)")
        }
        let targets = Dictionary(uniqueKeysWithValues: tree.layout(
            in: usable, gap: engine.gapSize, padding: engine.outerPadding
        ).map { ($0.0.windowID, $0.1) })
        XCTAssertEqual(actualFrames[501]?.width, targets[501].map { $0.width - 6 })
        XCTAssertEqual(actualFrames[502], targets[502])
        XCTAssertEqual(trace.restorationStarts, 0)
    }

    func testCellRoundedUpWindowTilesWithoutRestoringSiblings() {
        let first = makeWindow(id: 511)
        let second = makeWindow(id: 512)
        let tree = BSPTree()
        XCTAssertTrue(tree.insert(first, maxDepth: 3))
        XCTAssertTrue(tree.insert(second, maxDepth: 3))

        let usable = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let originals: [CGWindowID: CGRect] = [
            511: CGRect(x: 40, y: 40, width: 440, height: 620),
            512: CGRect(x: 520, y: 40, width: 440, height: 620)
        ]
        // whole-cell rounding the other way: one point wider, eight taller
        let trace = QuantizingSizingTrace(frames: originals, quantizedWindowID: 511,
                                          quantizationDelta: CGSize(width: 1, height: 8))
        let engine = TilingEngine(
            displayManager: DisplayManager(),
            frameSizingIOFactory: { _, generation in trace.io(generation: generation) }
        )

        let generation = engine.beginLayoutGeneration()
        let outcome = engine.applyVerifiedLayout(tree, in: usable, generation: generation)

        guard case let .accepted(actualFrames, _) = outcome else {
            return XCTFail("expected accepted rounded-up layout, got \(outcome)")
        }
        let targets = Dictionary(uniqueKeysWithValues: tree.layout(
            in: usable, gap: engine.gapSize, padding: engine.outerPadding
        ).map { ($0.0.windowID, $0.1) })
        XCTAssertEqual(actualFrames[511]?.width, targets[511].map { $0.width + 1 })
        XCTAssertEqual(actualFrames[511]?.height, targets[511].map { $0.height + 8 })
        XCTAssertEqual(actualFrames[512], targets[512])
        XCTAssertEqual(trace.restorationStarts, 0)
        XCTAssertNil(first.observedMinSize)
        XCTAssertEqual(tree.allWindows.map(\.windowID).sorted(), [511, 512])
    }

    func testAdjustedPassFailureRestoresOriginalFramesAndRatiosOnce() {
        let first = makeWindow(id: 1)
        let second = makeWindow(id: 2)
        let tree = BSPTree()
        XCTAssertTrue(tree.insert(first, maxDepth: 3))
        XCTAssertTrue(tree.insert(second, maxDepth: 3))

        let usable = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let originals: [CGWindowID: CGRect] = [
            1: CGRect(x: 40, y: 40, width: 440, height: 620),
            2: CGRect(x: 520, y: 40, width: 440, height: 620)
        ]
        let trace = SizingTrace(frames: originals)
        let engine = TilingEngine(
            displayManager: DisplayManager(),
            frameSizingIOFactory: { _, generation in trace.io(generation: generation) }
        )

        let initialRatio = tree.root.splitRatio
        let generation = engine.beginLayoutGeneration()
        let outcome = engine.applyVerifiedLayout(tree, in: usable, generation: generation)

        guard case .rejectedRestored = outcome else {
            return XCTFail("expected rejected layout with verified restoration, got \(outcome)")
        }
        XCTAssertEqual(tree.root.splitRatio, initialRatio, accuracy: 0.001)
        XCTAssertEqual(trace.frames, originals)
        XCTAssertEqual(trace.failedWrites, 1)
        XCTAssertEqual(trace.restoreApplications, 1)
    }

    func testDegradedOutcomeKeepsCandidateAndRestorationFailures() {
        let first = makeWindow(id: 1)
        let second = makeWindow(id: 2)
        let tree = BSPTree()
        XCTAssertTrue(tree.insert(first, maxDepth: 3))
        XCTAssertTrue(tree.insert(second, maxDepth: 3))

        let usable = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let trace = SizingTrace(frames: [
            1: CGRect(x: 40, y: 40, width: 440, height: 620),
            2: CGRect(x: 520, y: 40, width: 440, height: 620)
        ], restorationError: .notImplemented)
        let engine = TilingEngine(
            displayManager: DisplayManager(),
            frameSizingIOFactory: { _, generation in trace.io(generation: generation) }
        )

        let generation = engine.beginLayoutGeneration()
        let outcome = engine.applyVerifiedLayout(tree, in: usable, generation: generation)
        let reasons = degradedReasons(outcome)

        XCTAssertEqual(reasons.candidate, .writeFailed(1, .cannotComplete))
        XCTAssertEqual(reasons.restoration, .writeFailed(1, .notImplemented))
        XCTAssertTrue(reasons.attempted)
    }

    func testAcceptedLayoutCarriesCompleteWritesAndAStableReadback() {
        let first = makeWindow(id: 571)
        let second = makeWindow(id: 572)
        let tree = BSPTree()
        XCTAssertTrue(tree.insert(first, maxDepth: 3))
        XCTAssertTrue(tree.insert(second, maxDepth: 3))
        let engine = TilingEngine(displayManager: DisplayManager(),
                                  frameSizingIOFactory: acceptingFrameSizingIOFactory())

        let generation = engine.beginLayoutGeneration()
        let outcome = engine.applyVerifiedLayout(tree, in: CGRect(x: 0, y: 0, width: 1000, height: 700),
                                                 generation: generation)

        guard case let .accepted(_, progress) = outcome else {
            return XCTFail("expected accepted layout, got \(outcome)")
        }
        // this is what the publication gate reads
        XCTAssertEqual(Set(progress.candidate.targetIDs), [571, 572])
        XCTAssertEqual(progress.candidate.writesCompleted, [571, 572])
        XCTAssertTrue(progress.candidate.readbackComplete)
        XCTAssertTrue(progress.candidate.readbackStable)
        XCTAssertTrue(progress.candidateFullyWritten)
        XCTAssertNil(progress.restoration)
    }

    func testRestoredOverlappingOriginalsAreVerifiedAndReportedSeparately() {
        let first = makeWindow(id: 581)
        let second = makeWindow(id: 582)
        let tree = BSPTree()
        XCTAssertTrue(tree.insert(first, maxDepth: 3))
        XCTAssertTrue(tree.insert(second, maxDepth: 3))

        let usable = CGRect(x: 0, y: 0, width: 1000, height: 700)
        // both windows sit on the same spot, the way an untiled newcomer sits
        // over the incumbent it was admitted next to
        let stacked = CGRect(x: 40, y: 40, width: 400, height: 300)
        let trace = CappedSizingTrace(frames: [581: stacked, 582: stacked],
                                      cappedWindowID: 581,
                                      cap: CGSize(width: 400, height: 300))
        let engine = TilingEngine(
            displayManager: DisplayManager(),
            frameSizingIOFactory: { _, generation in trace.io(generation: generation) }
        )

        let generation = engine.beginLayoutGeneration()
        let outcome = engine.applyVerifiedLayout(tree, in: usable, generation: generation)

        guard case let .rejectedRestored(_, actualFrames, progress) = outcome else {
            return XCTFail("expected verified restoration, got \(outcome)")
        }
        XCTAssertEqual(actualFrames[581], stacked)
        XCTAssertEqual(actualFrames[582], stacked)
        XCTAssertEqual(progress.restorationOverlaps,
                       [FrameSizingOverlap(first: 581, second: 582)],
                       "the overlap is reported, not treated as a failed rollback")
        XCTAssertEqual(progress.restoration?.writesCompleted, [581, 582])
    }

    func testKeyboardSwapReturnsFalseAndRestoresTreeAfterUnknownRead() throws {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("no NSScreen available — swap integration requires a display")
        }
        let first = makeWindow(id: 11)
        let second = makeWindow(id: 12)
        let trace = OneUnknownReadTrace()
        let engine = TilingEngine(
            displayManager: DisplayManager(),
            frameSizingIOFactory: { _, generation in trace.io(generation: generation) }
        )
        _ = engine.prepareTileLayout([first, second], onWorkspace: 1, screen: screen)
        let tree = try XCTUnwrap(engine.existingTree(forWorkspace: 1, screen: screen))
        let originalOrder = tree.allWindows.map(\.windowID)
        trace.frames = Dictionary(uniqueKeysWithValues: tree.layout(
            in: engine.displayManager.cgRect(for: screen),
            gap: engine.gapSize,
            padding: engine.outerPadding
        ).map { ($0.0.windowID, $0.1) })

        let accepted = engine.swapWindows(first, second, onWorkspace: 1, screen: screen)

        XCTAssertFalse(accepted)
        XCTAssertEqual(tree.allWindows.map(\.windowID), originalOrder)
        XCTAssertEqual(trace.failedReads, 1)
        XCTAssertEqual(trace.restorationStarts, 1)
    }

    func testPreparedSwapReturnsFalseAndRestoresTreeAfterUnknownRead() throws {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("no NSScreen available — prepared swap requires a display")
        }
        let first = makeWindow(id: 21)
        let second = makeWindow(id: 22)
        let trace = OneUnknownReadTrace()
        let engine = TilingEngine(
            displayManager: DisplayManager(),
            frameSizingIOFactory: { _, generation in trace.io(generation: generation) }
        )
        _ = engine.prepareTileLayout([first, second], onWorkspace: 1, screen: screen)
        let tree = try XCTUnwrap(engine.existingTree(forWorkspace: 1, screen: screen))
        let originalOrder = tree.allWindows.map(\.windowID)
        let originals = Dictionary(uniqueKeysWithValues: tree.layout(
            in: engine.displayManager.cgRect(for: screen),
            gap: engine.gapSize,
            padding: engine.outerPadding
        ).map { ($0.0.windowID, $0.1) })
        trace.frames = originals

        let prepared = try XCTUnwrap(
            engine.prepareSwapLayout(first, second, onWorkspace: 1, screen: screen)
        )
        trace.frames = Dictionary(uniqueKeysWithValues: prepared.map { ($0.0.windowID, $0.1) })
        let accepted = engine.applyComputedLayout(onWorkspace: 1, screen: screen)

        XCTAssertFalse(accepted)
        XCTAssertEqual(tree.allWindows.map(\.windowID), originalOrder)
        XCTAssertEqual(trace.frames, originals)
        XCTAssertEqual(trace.failedReads, 1)
        XCTAssertEqual(trace.restorationStarts, 1)
    }

    func testPreparedToggleFailureRestoresPreAnimationFramesAndTree() throws {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("prepared toggle integration requires a display")
        }
        let first = makeWindow(id: 61)
        let second = makeWindow(id: 62)
        let trace = OneUnknownReadTrace()
        let engine = TilingEngine(
            displayManager: DisplayManager(),
            frameSizingIOFactory: { _, generation in trace.io(generation: generation) }
        )
        let initial = engine.prepareTileLayout([first, second], onWorkspace: 1, screen: screen)
        let tree = try XCTUnwrap(engine.existingTree(forWorkspace: 1, screen: screen))
        let originals = Dictionary(uniqueKeysWithValues: initial.map { ($0.0.windowID, $0.1) })
        let originalOverride = tree.root.splitOverride
        trace.frames = originals

        let prepared = try XCTUnwrap(
            engine.prepareToggleSplitLayout(first, onWorkspace: 1, screen: screen)
        )
        trace.frames = Dictionary(uniqueKeysWithValues: prepared.map { ($0.0.windowID, $0.1) })
        let accepted = engine.applyComputedLayout(onWorkspace: 1, screen: screen)

        XCTAssertFalse(accepted)
        XCTAssertEqual(tree.root.splitOverride, originalOverride)
        XCTAssertEqual(trace.frames, originals)
        XCTAssertEqual(trace.restorationStarts, 1)
    }

    func testOrdinaryLayoutEntryPointsRestoreFramesAfterUnknownRead() throws {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("ordinary layout integration requires a display")
        }
        let rect = CGRect(x: 30, y: 40, width: 900, height: 620)

        for entryPoint in OrdinaryEntryPoint.allCases {
            let first = makeWindow(id: entryPoint.baseID)
            let second = makeWindow(id: entryPoint.baseID + 1)
            let trace = OneUnknownReadTrace()
            let engine = TilingEngine(
                displayManager: DisplayManager(),
                frameSizingIOFactory: { _, generation in trace.io(generation: generation) }
            )
            let prepared = engine.prepareTileLayout([first, second], onWorkspace: 1, screen: screen)
            let originals = Dictionary(uniqueKeysWithValues: prepared.map { ($0.0.windowID, $0.1) })
            trace.frames = originals

            switch entryPoint {
            case .tileWindows:
                engine.tileWindows([first, second], onWorkspace: 1, screen: screen)
            case .tileScratchpad:
                _ = engine.tileScratchpad([first, second], screen: screen, in: rect)
            case .addWindowRetile:
                let third = makeWindow(id: entryPoint.baseID + 2)
                trace.frames[third.windowID] = CGRect(x: 100, y: 100, width: 300, height: 300)
                engine.addWindow(third, toWorkspace: 1, on: screen)
            case .computedLayout:
                _ = engine.prepareToggleSplitLayout(first, onWorkspace: 1, screen: screen)
                XCTAssertFalse(engine.applyComputedLayout(onWorkspace: 1, screen: screen))
            }

            XCTAssertEqual(trace.frames.filter { originals[$0.key] != nil }, originals,
                           "\(entryPoint) must restore actual pre-write frames")
            XCTAssertEqual(trace.restorationStarts, 1,
                           "\(entryPoint) must perform one verified restoration")
        }
    }

    func testMembershipChangeInvalidatesPreparedSwapWithoutRestoringOldState() throws {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("prepared operation integration requires a display")
        }
        let first = makeWindow(id: 51)
        let second = makeWindow(id: 52)
        let third = makeWindow(id: 53)
        let trace = OneUnknownReadTrace()
        let engine = TilingEngine(
            displayManager: DisplayManager(),
            frameSizingIOFactory: { _, generation in trace.io(generation: generation) }
        )
        let initial = engine.prepareTileLayout([first, second], onWorkspace: 1, screen: screen)
        trace.frames = Dictionary(uniqueKeysWithValues: initial.map { ($0.0.windowID, $0.1) })
        _ = try XCTUnwrap(engine.prepareSwapLayout(first, second, onWorkspace: 1, screen: screen))

        let newer = engine.prepareTileLayout([first, second, third], onWorkspace: 1, screen: screen)
        trace.frames = Dictionary(uniqueKeysWithValues: newer.map { ($0.0.windowID, $0.1) })
        let newerFrames = trace.frames
        let accepted = engine.applyComputedLayout(onWorkspace: 1, screen: screen)

        XCTAssertFalse(accepted)
        XCTAssertEqual(engine.existingTree(forWorkspace: 1, screen: screen)?.allWindows.map(\.windowID),
                       [second.windowID, first.windowID, third.windowID])
        XCTAssertEqual(trace.frames, newerFrames)
        XCTAssertEqual(trace.restorationStarts, 1)
    }

    func testFailedDirectMutationsRestoreTreeStateAndFrames() throws {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("direct mutation integration requires a display")
        }

        for mutation in DirectMutation.allCases {
            let first = makeWindow(id: mutation.baseID)
            let second = makeWindow(id: mutation.baseID + 1)
            let trace = OneUnknownReadTrace()
            let engine = TilingEngine(
                displayManager: DisplayManager(),
                frameSizingIOFactory: { _, generation in trace.io(generation: generation) }
            )
            let prepared = engine.prepareTileLayout([first, second], onWorkspace: 1, screen: screen)
            let tree = try XCTUnwrap(engine.existingTree(forWorkspace: 1, screen: screen))
            let originals = Dictionary(uniqueKeysWithValues: prepared.map { ($0.0.windowID, $0.1) })
            trace.frames = originals
            let ratio = tree.root.splitRatio
            let userSetRatio = tree.root.userSetRatio
            let splitOverride = tree.root.splitOverride

            switch mutation {
            case .applyResize:
                var resized = try XCTUnwrap(originals[first.windowID])
                resized.size.width += 80
                engine.applyResize(first, newFrame: resized, onWorkspace: 1, screen: screen)
            case .toggleSplit:
                engine.toggleSplit(first, onWorkspace: 1, screen: screen)
            case .resizeInDirection:
                engine.resizeInDirection(first, direction: .right, onWorkspace: 1, screen: screen)
            }

            XCTAssertEqual(tree.root.splitRatio, ratio, accuracy: 0.001, "\(mutation)")
            XCTAssertEqual(tree.root.userSetRatio, userSetRatio, "\(mutation)")
            XCTAssertEqual(tree.root.splitOverride, splitOverride, "\(mutation)")
            XCTAssertEqual(trace.frames, originals, "\(mutation)")
            XCTAssertEqual(trace.restorationStarts, 1, "\(mutation)")
        }
    }

    func testReentrantStateChangesSupersedeActiveLayoutWithoutOldRollback() throws {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("generation integration requires a display")
        }

        for change in ReentrantStateChange.allCases {
            let first = makeWindow(id: change.baseID)
            let second = makeWindow(id: change.baseID + 1)
            let trace = ReentrantMutationTrace()
            let engine = TilingEngine(
                displayManager: DisplayManager(),
                frameSizingIOFactory: { _, generation in trace.io(generation: generation) }
            )
            let prepared = engine.prepareTileLayout([first, second], onWorkspace: 1, screen: screen)
            trace.frames = Dictionary(uniqueKeysWithValues: prepared.map { ($0.0.windowID, $0.1) })
            if change == .forceInsertNoFit {
                engine.maxSplitsPerMonitor[screen.localizedName] = 0
            }
            trace.onFirstRead = {
                switch change {
                case .gap: engine.gapSize += 1
                case .padding: engine.outerPadding += 1
                case .removeWindow: engine.removeWindowID(second.windowID)
                case .display: engine.handleDisplayChange(currentScreens: [], homeScreenForWorkspace: { _ in nil })
                case .prepareToggle:
                    _ = engine.prepareToggleSplitLayout(first, onWorkspace: 1, screen: screen)
                case .forceInsertNoFit:
                    _ = engine.forceInsertWindow(
                        makeWindow(id: change.baseID + 2), toWorkspace: 1, on: screen
                    )
                }
            }

            let accepted = engine.applyComputedLayout(onWorkspace: 1, screen: screen)

            XCTAssertFalse(accepted, "\(change) must supersede the active layout")
            XCTAssertEqual(trace.restorationStarts, 0, "\(change) must not restore stale frames")
        }
    }

    func testHiddenOriginalsAreNotRestoredAfterUnknownCandidateRead() {
        assertHiddenOriginalsAreNotRestored(
            mode: .unknownRead,
            expectedReason: .readFailed(401, .cannotComplete)
        )
    }

    func testHiddenOriginalsAreNotRestoredAfterCandidateDeadline() {
        assertHiddenOriginalsAreNotRestored(
            mode: .deadline,
            expectedReason: .deadlineExceeded
        )
    }

    func testHiddenOriginalsAreNotRestoredAfterKnownPositionRefusal() {
        assertHiddenOriginalsAreNotRestored(
            mode: .positionRefusal,
            expectedReason: .geometryMismatch(401)
        )
    }

    func testHiddenOriginalsCanCompleteVerifiedReveal() {
        let fixture = hiddenOriginalFixture(mode: .success)

        let outcome = fixture.engine.applyVerifiedLayout(
            fixture.tree, in: fixture.usable, generation: fixture.generation
        )

        guard case .accepted = outcome else {
            return XCTFail("expected accepted reveal, got \(outcome)")
        }
        XCTAssertEqual(fixture.trace.frames, fixture.targets)
        XCTAssertTrue(fixture.trace.hiddenPositionWrites.isEmpty)
    }

    func testAdjustedPassLowersTheBoundToTheSizeItActuallyAccepted() {
        let first = makeWindow(id: 601)
        let second = makeWindow(id: 602)
        let tree = BSPTree()
        XCTAssertTrue(tree.insert(first, maxDepth: 3))
        XCTAssertTrue(tree.insert(second, maxDepth: 3))

        let usable = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let trace = TwoPassSizingTrace(frames: [
            601: CGRect(x: 40, y: 40, width: 440, height: 620),
            602: CGRect(x: 520, y: 40, width: 440, height: 620)
        ], conflictedWindowID: 601, candidateOvershoot: 100, adjustedUndershoot: 15)
        let engine = TilingEngine(
            displayManager: DisplayManager(),
            frameSizingIOFactory: { _, generation in trace.io(generation: generation) }
        )
        let candidateTargets = Dictionary(uniqueKeysWithValues: tree.layout(
            in: usable, gap: engine.gapSize, padding: engine.outerPadding
        ).map { ($0.0.windowID, $0.1) })
        let refusedWidth = candidateTargets[601]!.width + 100

        let generation = engine.beginLayoutGeneration()
        let outcome = engine.applyVerifiedLayout(tree, in: usable, generation: generation)

        guard case .accepted = outcome else {
            return XCTFail("expected the adjusted pass to be accepted, got \(outcome)")
        }
        let accepted = trace.frames[601]!.width
        XCTAssertLessThan(accepted, refusedWidth - TilingConfig.lowerMinSizeAcceptedDeltaPx,
                          "the fake must accept a width the candidate pass refused")
        XCTAssertEqual(first.observedMinSize?.width, accepted,
                       "the bound must follow the accepted readback, not the tile we asked for")
        XCTAssertEqual(first.observedMinSize?.height, 0,
                       "nothing refused a height, so the height stays unknown")
    }

    private func assertHiddenOriginalsAreNotRestored(
        mode: HiddenOriginalTrace.Mode,
        expectedReason: FrameSizingFailure
    ) {
        let fixture = hiddenOriginalFixture(mode: mode)

        let outcome = fixture.engine.applyVerifiedLayout(
            fixture.tree, in: fixture.usable, generation: fixture.generation
        )
        let reasons = degradedReasons(outcome)

        XCTAssertEqual(reasons.candidate, expectedReason)
        XCTAssertEqual(reasons.restoration, .outsideUsableFrame(401))
        XCTAssertFalse(reasons.attempted, "the pre-check must not have run restoration")
        XCTAssertTrue(fixture.trace.hiddenPositionWrites.isEmpty,
                      "invalid offscreen originals must be rejected before recovery writes")
        XCTAssertTrue(fixture.trace.frames.values.allSatisfy { fixture.usable.contains($0) },
                      "the completed candidate writes must remain visible")
    }

    private func hiddenOriginalFixture(
        mode: HiddenOriginalTrace.Mode
    ) -> (engine: TilingEngine, tree: BSPTree, trace: HiddenOriginalTrace,
          usable: CGRect, targets: [CGWindowID: CGRect], generation: UInt64) {
        let first = makeWindow(id: 401)
        let second = makeWindow(id: 402)
        let tree = BSPTree()
        XCTAssertTrue(tree.insert(first, maxDepth: 3))
        XCTAssertTrue(tree.insert(second, maxDepth: 3))

        let usable = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let hidden: [CGWindowID: CGRect] = [
            401: CGRect(x: 999, y: 699, width: 480, height: 620),
            402: CGRect(x: 999, y: 699, width: 480, height: 620)
        ]
        let trace = HiddenOriginalTrace(frames: hidden, hiddenFrames: hidden, mode: mode)
        let engine = TilingEngine(
            displayManager: DisplayManager(),
            frameSizingIOFactory: { _, generation in trace.io(generation: generation) }
        )
        let targets = Dictionary(uniqueKeysWithValues: tree.layout(
            in: usable, gap: engine.gapSize, padding: engine.outerPadding
        ).map { ($0.0.windowID, $0.1) })
        let generation = engine.beginLayoutGeneration()
        return (engine, tree, trace, usable, targets, generation)
    }

}

private enum DirectMutation: CaseIterable {
    case applyResize, toggleSplit, resizeInDirection

    var baseID: CGWindowID {
        switch self {
        case .applyResize: 201
        case .toggleSplit: 211
        case .resizeInDirection: 221
        }
    }
}

private enum ReentrantStateChange: CaseIterable, Equatable {
    case gap, padding, removeWindow, display, prepareToggle, forceInsertNoFit

    var baseID: CGWindowID {
        switch self {
        case .gap: 301
        case .padding: 311
        case .removeWindow: 321
        case .display: 331
        case .prepareToggle: 341
        case .forceInsertNoFit: 351
        }
    }
}

private enum OrdinaryEntryPoint: CaseIterable {
    case tileWindows, tileScratchpad, addWindowRetile, computedLayout

    var baseID: CGWindowID {
        switch self {
        case .tileWindows: 101
        case .tileScratchpad: 111
        case .addWindowRetile: 121
        case .computedLayout: 131
        }
    }
}

private func degradedReasons(
    _ outcome: TilingEngine.LayoutApplicationOutcome
) -> (candidate: FrameSizingFailure?, restoration: FrameSizingFailure?, attempted: Bool) {
    guard case let .degraded(candidateReason, restorationReason, attempted, _, _) = outcome else {
        return (nil, nil, false)
    }
    return (candidateReason, restorationReason, attempted)
}

private final class SizingTrace {
    var frames: [CGWindowID: CGRect]
    var now: TimeInterval = 0
    var sizeWrites = 0
    var failedWrites = 0
    var restoreApplications = 0
    private var currentTargets: [CGWindowID: CGRect] = [:]
    private let restorationError: AXError?

    init(frames: [CGWindowID: CGRect], restorationError: AXError? = nil) {
        self.frames = frames
        self.restorationError = restorationError
    }

    func io(generation: @escaping () -> UInt64) -> FrameSizingIO {
        return FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { [self] id, size, _ in
                sizeWrites += 1
                // two windows consume four size writes in pass 1. Fail the first
                // write of the adjusted pass, then allow one restoration pass.
                if sizeWrites == 5 {
                    failedWrites += 1
                    return .cannotComplete
                }
                if sizeWrites == 6 {
                    restoreApplications += 1
                    if let restorationError { return restorationError }
                }
                var frame = frames[id] ?? .zero
                frame.size = size
                frames[id] = frame
                currentTargets[id] = frame
                return .success
            },
            writePosition: { [self] id, position, _ in
                var frame = frames[id] ?? .zero
                frame.origin = position
                frames[id] = frame
                currentTargets[id] = frame
                return .success
            },
            readPosition: { [self] id, _ in (.success, frames[id]?.origin) },
            readSize: { [self] id, _ in
                guard var size = frames[id]?.size else { return (.invalidUIElement, nil) }
                // Pass 1 settles with window 1 wider than its allocation. That
                // gives the engine one actionable minimum-size conflict.
                if sizeWrites == 4, id == 1 { size.width += 100 }
                return (.success, size)
            },
            now: { [self] in now },
            sleep: { [self] interval in now += interval },
            currentGeneration: generation
        )
    }
}

/// One window refuses the candidate tile by `candidateOvershoot` points of
/// width, then accepts the adjusted tile `adjustedUndershoot` points short
/// of what it was asked for. Everything lands at the origin it was given.
private final class TwoPassSizingTrace {
    var frames: [CGWindowID: CGRect]
    private var now: TimeInterval = 0
    private let conflictedWindowID: CGWindowID
    private let candidateOvershoot: CGFloat
    private let adjustedUndershoot: CGFloat
    private var hasWritten = false
    private var sawRead = false
    private var pass = 1

    init(frames: [CGWindowID: CGRect], conflictedWindowID: CGWindowID,
         candidateOvershoot: CGFloat, adjustedUndershoot: CGFloat) {
        self.frames = frames
        self.conflictedWindowID = conflictedWindowID
        self.candidateOvershoot = candidateOvershoot
        self.adjustedUndershoot = adjustedUndershoot
    }

    func io(generation: @escaping () -> UInt64) -> FrameSizingIO {
        FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { [self] id, size, _ in
                // a write after a readback means the next pass has started
                if sawRead { pass += 1; sawRead = false }
                hasWritten = true
                var frame = frames[id] ?? .zero
                frame.size = size
                if id == conflictedWindowID {
                    frame.size.width += pass == 1 ? candidateOvershoot : -adjustedUndershoot
                }
                frames[id] = frame
                return .success
            },
            writePosition: { [self] id, position, _ in
                var frame = frames[id] ?? .zero
                frame.origin = position
                frames[id] = frame
                return .success
            },
            readPosition: { [self] id, _ in
                if hasWritten { sawRead = true }
                return (.success, frames[id]?.origin)
            },
            readSize: { [self] id, _ in (.success, frames[id]?.size) },
            now: { [self] in now },
            sleep: { [self] interval in now += interval },
            currentGeneration: generation
        )
    }
}

private final class QuantizingSizingTrace {
    var frames: [CGWindowID: CGRect]
    var restorationStarts = 0
    private var now: TimeInterval = 0
    private var hasWritten = false
    private var candidateWasRead = false
    private let quantizedWindowID: CGWindowID
    private let quantizationDelta: CGSize

    init(frames: [CGWindowID: CGRect], quantizedWindowID: CGWindowID,
         quantizationDelta: CGSize = CGSize(width: -6, height: 0)) {
        self.frames = frames
        self.quantizedWindowID = quantizedWindowID
        self.quantizationDelta = quantizationDelta
    }

    func io(generation: @escaping () -> UInt64) -> FrameSizingIO {
        FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { [self] id, size, _ in
                if candidateWasRead { restorationStarts += 1 }
                hasWritten = true
                var frame = frames[id] ?? .zero
                frame.size = size
                if id == quantizedWindowID {
                    frame.size.width += quantizationDelta.width
                    frame.size.height += quantizationDelta.height
                }
                frames[id] = frame
                return .success
            },
            writePosition: { [self] id, position, _ in
                var frame = frames[id] ?? .zero
                frame.origin = position
                frames[id] = frame
                return .success
            },
            readPosition: { [self] id, _ in
                if hasWritten { candidateWasRead = true }
                return (.success, frames[id]?.origin)
            },
            readSize: { [self] id, _ in (.success, frames[id]?.size) },
            now: { [self] in now },
            sleep: { [self] interval in now += interval },
            currentGeneration: generation
        )
    }
}

private final class OneUnknownReadTrace {
    var frames: [CGWindowID: CGRect] = [:]
    var now: TimeInterval = 0
    var failedReads = 0
    var restorationStarts = 0
    private var hasWritten = false
    private var didFail = false
    private var countedRestoration = false

    func io(generation: @escaping () -> UInt64) -> FrameSizingIO {
        FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { [self] id, size, _ in
                if didFail && !countedRestoration {
                    restorationStarts += 1
                    countedRestoration = true
                }
                hasWritten = true
                var frame = frames[id] ?? .zero
                frame.size = size
                frames[id] = frame
                return .success
            },
            writePosition: { [self] id, position, _ in
                var frame = frames[id] ?? .zero
                frame.origin = position
                frames[id] = frame
                return .success
            },
            readPosition: { [self] id, _ in
                if hasWritten && !didFail {
                    didFail = true
                    failedReads += 1
                    return (.cannotComplete, nil)
                }
                return (.success, frames[id]?.origin)
            },
            readSize: { [self] id, _ in (.success, frames[id]?.size) },
            now: { [self] in now },
            sleep: { [self] interval in now += interval },
            currentGeneration: generation
        )
    }
}

private final class HiddenOriginalTrace {
    enum Mode: Equatable {
        case success
        case unknownRead
        case deadline
        case positionRefusal
    }

    var frames: [CGWindowID: CGRect]
    var hiddenPositionWrites: [(CGWindowID, CGPoint)] = []
    private var now: TimeInterval = 0
    private var sizeWrites = 0
    private var failedRead = false
    private let hiddenFrames: [CGWindowID: CGRect]
    private let mode: Mode

    init(frames: [CGWindowID: CGRect], hiddenFrames: [CGWindowID: CGRect], mode: Mode) {
        self.frames = frames
        self.hiddenFrames = hiddenFrames
        self.mode = mode
    }

    func io(generation: @escaping () -> UInt64) -> FrameSizingIO {
        FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { [self] id, size, _ in
                sizeWrites += 1
                var frame = frames[id] ?? .zero
                frame.size = size
                frames[id] = frame
                if mode == .deadline, sizeWrites == 4 { now = 1 }
                return .success
            },
            writePosition: { [self] id, position, _ in
                if hiddenFrames[id]?.origin == position {
                    hiddenPositionWrites.append((id, position))
                }
                var frame = frames[id] ?? .zero
                frame.origin = mode == .positionRefusal
                    ? CGPoint(x: position.x + 5, y: position.y)
                    : position
                frames[id] = frame
                return .success
            },
            readPosition: { [self] id, _ in
                if mode == .unknownRead, sizeWrites >= 4, !failedRead {
                    failedRead = true
                    return (.cannotComplete, nil)
                }
                return (.success, frames[id]?.origin)
            },
            readSize: { [self] id, _ in (.success, frames[id]?.size) },
            now: { [self] in now },
            sleep: { [self] interval in now += interval },
            currentGeneration: generation
        )
    }
}

private final class ReentrantMutationTrace {
    var frames: [CGWindowID: CGRect] = [:]
    var now: TimeInterval = 0
    var restorationStarts = 0
    var onFirstRead: (() -> Void)?
    private var hasWritten = false
    private var didMutate = false
    private var staleGenerations: Set<UInt64> = []

    func io(generation: @escaping () -> UInt64) -> FrameSizingIO {
        let operationGeneration = generation()
        return FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { [self] id, size, _ in
                if didMutate, staleGenerations.contains(operationGeneration) {
                    restorationStarts += 1
                }
                hasWritten = true
                var frame = frames[id] ?? .zero
                frame.size = size
                frames[id] = frame
                return .success
            },
            writePosition: { [self] id, position, _ in
                var frame = frames[id] ?? .zero
                frame.origin = position
                frames[id] = frame
                return .success
            },
            readPosition: { [self] id, _ in
                if hasWritten && !didMutate {
                    didMutate = true
                    staleGenerations.insert(operationGeneration)
                    onFirstRead?()
                }
                return (.success, frames[id]?.origin)
            },
            readSize: { [self] id, _ in (.success, frames[id]?.size) },
            now: { [self] in now },
            sleep: { [self] interval in now += interval },
            currentGeneration: generation
        )
    }
}

/// Writes always land, except that one window refuses to grow past a cap.
/// The candidate therefore reads back short of its target while every
/// original still fits, so the restoration pass writes each window back
/// exactly where it was.
private final class CappedSizingTrace {
    var frames: [CGWindowID: CGRect]
    private var now: TimeInterval = 0
    private let cappedWindowID: CGWindowID
    private let cap: CGSize

    init(frames: [CGWindowID: CGRect], cappedWindowID: CGWindowID, cap: CGSize) {
        self.frames = frames
        self.cappedWindowID = cappedWindowID
        self.cap = cap
    }

    func io(generation: @escaping () -> UInt64) -> FrameSizingIO {
        FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { [self] id, size, _ in
                var frame = frames[id] ?? .zero
                frame.size = id == cappedWindowID
                    ? CGSize(width: min(size.width, cap.width), height: min(size.height, cap.height))
                    : size
                frames[id] = frame
                return .success
            },
            writePosition: { [self] id, position, _ in
                var frame = frames[id] ?? .zero
                frame.origin = position
                frames[id] = frame
                return .success
            },
            readPosition: { [self] id, _ in (.success, frames[id]?.origin) },
            readSize: { [self] id, _ in (.success, frames[id]?.size) },
            now: { [self] in now },
            sleep: { [self] interval in now += interval },
            currentGeneration: generation
        )
    }
}
