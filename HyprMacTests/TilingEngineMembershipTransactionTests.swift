import XCTest
@testable import HyprMac

final class TilingEngineMembershipTransactionTests: XCTestCase {
    func testRejectedMembershipKeepsPriorTreeAndActualFrames() throws {
        let f = try fixture()
        f.trace.rejectNextRead = true
        let before = f.tree.structuralFingerprint()
        let originals = f.trace.frames

        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        XCTAssertEqual(f.engine.existingTree(forWorkspace: 1, screen: f.screen)?.structuralFingerprint(), before)
        XCTAssertEqual(f.trace.frames, originals)
    }

    func testMembershipIsNotPublishedDuringAXWrites() throws {
        let f = try fixture()
        let before = f.tree.structuralFingerprint()
        var observed: [BSPTree.StructuralFingerprint] = []
        f.trace.onWrite = {
            if let tree = f.engine.existingTree(forWorkspace: 1, screen: f.screen) {
                observed.append(tree.structuralFingerprint())
            }
        }

        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        XCTAssertFalse(observed.isEmpty)
        XCTAssertTrue(observed.allSatisfy { $0 == before })
        XCTAssertEqual(Set(f.engine.existingTree(forWorkspace: 1, screen: f.screen)?.allWindows.map(\.windowID) ?? []), Set(f.windows.map(\.windowID)))
    }

    func testRejectedAddWindowKeepsPriorMembership() throws {
        let f = try fixture()
        f.trace.rejectNextRead = true
        let before = f.tree.structuralFingerprint()

        f.engine.addWindow(f.windows[2], toWorkspace: 1, on: f.screen)

        XCTAssertEqual(f.engine.existingTree(forWorkspace: 1, screen: f.screen)?.structuralFingerprint(), before)
    }

    func testFitProbeChecksCompleteHiddenWorkspaceWithoutPublishingTree() throws {
        let f = try fixture()
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        let windows = Array(f.windows.prefix(2))
        for window in windows {
            window.observedMinSize = CGSize(width: usable.width * 0.7, height: usable.height * 0.7)
        }
        var writes = 0
        f.trace.onWrite = { writes += 1 }

        XCTAssertFalse(f.engine.canFitWindows(windows, onWorkspace: 2, screen: f.screen))
        XCTAssertNil(f.engine.existingTree(forWorkspace: 2, screen: f.screen))
        XCTAssertEqual(writes, 0)
    }

    func testFitProbeAcceptsCapacityAndRejectsDuplicatesWithoutWrites() throws {
        let f = try fixture()
        var writes = 0
        f.trace.onWrite = { writes += 1 }
        XCTAssertTrue(f.engine.canFitWindows(f.windows, onWorkspace: 2, screen: f.screen))
        XCTAssertFalse(f.engine.canFitWindows([f.windows[0], f.windows[0]], onWorkspace: 2, screen: f.screen))
        XCTAssertEqual(writes, 0)
    }

    func testUnreadableScratchpadCandidateKeepsPriorMembership() throws {
        let f = try fixture()
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        f.engine.tileScratchpad(Array(f.windows.prefix(2)), screen: f.screen, in: usable)
        let before = try XCTUnwrap(f.engine.existingTree(forWorkspace: 0, screen: f.screen)).structuralFingerprint()
        f.trace.rejectNextRead = true

        f.engine.tileScratchpad(f.windows, screen: f.screen, in: usable)

        XCTAssertEqual(f.engine.existingTree(forWorkspace: 0, screen: f.screen)?.structuralFingerprint(), before)
    }

    func testFailedFirstTileDoesNotPublishEmptyTree() throws {
        let f = try fixture()
        f.trace.rejectNextRead = true
        f.engine.tileWindows(f.windows, onWorkspace: 3, screen: f.screen)
        XCTAssertNil(f.engine.existingTree(forWorkspace: 3, screen: f.screen))
    }

    func testFailedScratchpadMigrationKeepsSourceTreeAndDoesNotPublishDestination() throws {
        let f = try fixture()
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        f.engine.tileScratchpad(Array(f.windows.prefix(2)), screen: f.screen, in: usable)
        let before = try XCTUnwrap(f.engine.existingTree(forWorkspace: 0, screen: f.screen)).structuralFingerprint()
        let destination = MembershipTestScreen()
        f.trace.rejectNextRead = true

        f.engine.tileScratchpad(f.windows, screen: destination, in: CGRect(x: 4000, y: 0, width: 1600, height: 1000))

        XCTAssertEqual(f.engine.existingTree(forWorkspace: 0, screen: f.screen)?.structuralFingerprint(), before)
        XCTAssertNil(f.engine.existingTree(forWorkspace: 0, screen: destination))
        XCTAssertFalse(unverifiedIDs(f.engine, workspace: TilingEngine.scratchpadWorkspace).isEmpty)
    }

    func testDegradedLayoutWithFailedRestorationKeepsPriorMembership() throws {
        let f = try fixture()
        // restoration runs and fails: the window will not shrink back to its
        // original, so the screen is near the originals, not the candidate
        f.trace.minSize[f.windows[0].windowID] = CGSize(width: 300, height: 300)
        let before = f.tree.structuralFingerprint()
        f.trace.rejectNextRead = true

        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        XCTAssertEqual(f.engine.existingTree(forWorkspace: 1, screen: f.screen)?.structuralFingerprint(), before)
    }

    func testSecondTargetFailureWithParkedOriginalsPublishesNothingAndWritesNoParkedFrame() throws {
        let f = try fixture()
        // originals parked off the usable frame, so they are not restoration
        // targets. every target is written, then the second one will not read
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        let parked = CGRect(x: usable.maxX + 200, y: usable.minY + 20, width: 120, height: 120)
        for window in f.windows { f.trace.frames[window.windowID] = parked }
        f.trace.rejectReadsFor = [f.windows[1].windowID]
        let before = f.tree.structuralFingerprint()

        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        XCTAssertEqual(f.engine.existingTree(forWorkspace: 1, screen: f.screen)?.structuralFingerprint(), before)
        XCTAssertEqual(f.trace.written, Set(f.windows.map(\.windowID)))
        XCTAssertFalse(f.trace.requested.values.contains { $0.origin == parked.origin },
                       "a parked original is never written back")
        XCTAssertEqual(unverifiedIDs(f.engine, workspace: 1), Set(f.windows.map(\.windowID)))
    }

    func testParkedOriginalsKeepThePriorRatiosAsWellAsTheMembership() throws {
        let f = try fixture()
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        // one window refuses to shrink, so pass 1 conflicts and pass 2
        // re-splits around it; the floor is unsatisfiable, so pass 2 fails too
        f.trace.minSize[f.windows[0].windowID] = CGSize(width: usable.width * 1.2, height: 0)
        for window in f.windows {
            f.trace.frames[window.windowID] = CGRect(x: usable.maxX + 200, y: usable.minY + 20,
                                                     width: 120, height: 120)
        }

        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        // a recorded minimum proves pass 1 rejected with a conflict, which is
        // what sends the transaction into the adjusted second pass
        XCTAssertNotNil(f.windows[0].observedMinSize)
        let published = try XCTUnwrap(f.engine.existingTree(forWorkspace: 1, screen: f.screen))
        XCTAssertEqual(Set(published.allWindows.map(\.windowID)),
                       Set(f.windows.prefix(2).map(\.windowID)))
        XCTAssertEqual(published.root.splitRatio, 0.6, accuracy: 0.0001,
                       "an unverified adjusted pass does not get to rewrite the live ratios")
    }

    func testCleanupFailureDoesNotPublishEvenThoughTheFramesReadBackFine() throws {
        let f = try fixture()
        // every setter succeeds and the frames land exactly where they were
        // asked to; only the EnhancedUI cleanup errors
        f.trace.endError = .cannotComplete
        let before = f.tree.structuralFingerprint()

        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        XCTAssertEqual(f.engine.existingTree(forWorkspace: 1, screen: f.screen)?.structuralFingerprint(), before)
        XCTAssertFalse(unverifiedIDs(f.engine, workspace: 1).isEmpty)
    }

    func testIncompleteReadbackDoesNotPublish() throws {
        let f = try fixture()
        // one window never reads back, so the final readback is incomplete
        // whatever the others say
        f.trace.rejectReadsFor = [f.windows[2].windowID]
        let before = f.tree.structuralFingerprint()

        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        XCTAssertEqual(f.engine.existingTree(forWorkspace: 1, screen: f.screen)?.structuralFingerprint(), before)
        XCTAssertFalse(unverifiedIDs(f.engine, workspace: 1).isEmpty)
    }

    func testWindowThatStopsShortOfItsTargetKeepsThePriorMembership() throws {
        let f = try fixture()
        // the portrait Terminal: asked for the full slot height, answers 340
        // points short, every time
        f.trace.heightShortfall[f.windows[0].windowID] = 340
        let before = f.tree.structuralFingerprint()

        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        XCTAssertEqual(f.engine.existingTree(forWorkspace: 1, screen: f.screen)?.structuralFingerprint(), before)
        XCTAssertEqual(f.engine.existingTree(forWorkspace: 1, screen: f.screen)?.root.splitRatio, 0.6)
        XCTAssertFalse(unverifiedIDs(f.engine, workspace: 1).isEmpty)
    }

    func testAcceptedRetryPublishesAndClearsTheUnverifiedMark() throws {
        let f = try fixture()
        f.trace.rejectNextRead = true
        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)
        XCTAssertFalse(unverifiedIDs(f.engine, workspace: 1).isEmpty)

        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        XCTAssertEqual(Set(f.engine.windowIDs(inTreeForWorkspace: 1, screen: f.screen)),
                       Set(f.windows.map(\.windowID)))
        XCTAssertTrue(unverifiedIDs(f.engine, workspace: 1).isEmpty)
    }

    func testSupersededLayoutLeavesNoUnverifiedMarkBehindForANewerAcceptedOne() throws {
        let f = try fixture()
        var bumped = false
        f.trace.onWrite = {
            guard !bumped else { return }
            bumped = true
            f.engine.beginLayoutGeneration()
        }

        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        XCTAssertTrue(bumped)
        XCTAssertTrue(unverifiedIDs(f.engine, workspace: 1).isEmpty,
                      "a superseded generation does not get to mark a key a newer owner holds")
        // and nothing was rolled back over the newer operation
        XCTAssertEqual(f.trace.written.count, 1)
    }

    func testOverlappingOriginalsRestoreWithoutPublishingThemAsATiledLayout() throws {
        let f = try fixture()
        // the originals sit on top of each other, the way an untiled newcomer
        // and an incumbent do
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        let stacked = CGRect(x: usable.minX + 40, y: usable.minY + 40, width: 400, height: 300)
        for window in f.windows { f.trace.frames[window.windowID] = stacked }
        f.trace.rejectNextRead = true
        let before = f.tree.structuralFingerprint()

        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        XCTAssertEqual(f.engine.existingTree(forWorkspace: 1, screen: f.screen)?.structuralFingerprint(), before)
        for window in f.windows {
            XCTAssertEqual(f.trace.frames[window.windowID], stacked,
                           "every original goes back exactly where it was")
        }
    }

    private func unverifiedIDs(_ engine: TilingEngine, workspace: Int) -> Set<CGWindowID> {
        engine.unverifiedLayouts.filter { $0.workspace == workspace }
            .reduce(into: Set<CGWindowID>()) { $0.formUnion($1.windowIDs) }
    }

    func testDegradedLayoutWithoutWritesKeepsPriorMembership() throws {
        let f = try fixture()
        // no capture for the new window, so the transaction gives up before
        // any AX write happens
        f.trace.frames.removeValue(forKey: f.windows[2].windowID)
        let before = f.tree.structuralFingerprint()
        var writes = 0
        f.trace.onWrite = { writes += 1 }

        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        XCTAssertEqual(writes, 0)
        XCTAssertEqual(f.engine.existingTree(forWorkspace: 1, screen: f.screen)?.structuralFingerprint(), before)
    }

    private func fixture() throws -> (engine: TilingEngine, tree: BSPTree, windows: [HyprWindow], screen: NSScreen, trace: MembershipTrace) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { throw XCTSkip("requires display geometry") }
        let windows = (901...903).map { id in
            HyprWindow(element: AXUIElementCreateApplication(99999), windowID: CGWindowID(id), ownerPID: 99999)
        }
        let trace = MembershipTrace()
        let engine = TilingEngine(displayManager: DisplayManager(), frameSizingIOFactory: { _, generation in trace.io(generation) })
        _ = engine.prepareTileLayout(Array(windows.prefix(2)), onWorkspace: 1, screen: screen)
        let tree = try XCTUnwrap(engine.existingTree(forWorkspace: 1, screen: screen))
        tree.root.splitRatio = 0.6
        tree.root.userSetRatio = true
        let usable = engine.displayManager.cgRect(for: screen)
        for (index, window) in windows.enumerated() {
            trace.frames[window.windowID] = CGRect(x: usable.minX + 20 + CGFloat(index) * 150,
                                                   y: usable.minY + 20, width: 120, height: 120)
        }
        return (engine, tree, windows, screen, trace)
    }
}

private final class MembershipTrace {
    var frames: [CGWindowID: CGRect] = [:]
    var rejectNextRead = false
    /// windows whose reads fail from the first write onwards, so a failure
    /// can be aimed at one target instead of whichever is read first
    var rejectReadsFor: Set<CGWindowID> = []
    var onWrite: (() -> Void)?
    /// floor a window refuses to shrink below, the way a real min-size app behaves
    var minSize: [CGWindowID: CGSize] = [:]
    /// how far short of the height it is asked for a window settles — the
    /// portrait Terminal case, which answers short whatever the ask
    var heightShortfall: [CGWindowID: CGFloat] = [:]
    /// error the EnhancedUI cleanup returns after the setters have all
    /// succeeded, so a clean-looking frame still ends in a failure
    var endError: AXError?
    /// the frames the engine asked for, before any floor is applied
    var requested: [CGWindowID: CGRect] = [:]
    /// every window a setter went out for
    var written: Set<CGWindowID> = []
    private var wrote = false
    private var now: TimeInterval = 0

    func io(_ generation: @escaping () -> UInt64) -> FrameSizingIO {
        var io = FrameSizingIO(setMessagingTimeout: { _, _ in .success },
                      writeSize: { [self] id, size, _ in
                          onWrite?(); wrote = true; written.insert(id)
                          requested[id, default: .zero].size = size
                          let floor = minSize[id] ?? .zero
                          let short = heightShortfall[id] ?? 0
                          frames[id]?.size = CGSize(width: max(size.width, floor.width),
                                                    height: max(size.height - short, floor.height))
                          return .success
                      },
                      writePosition: { [self] id, position, _ in
                          onWrite?(); written.insert(id)
                          requested[id, default: .zero].origin = position
                          frames[id]?.origin = position
                          return .success
                      },
                      readPosition: { [self] id, _ in
                          if wrote && rejectReadsFor.contains(id) { return (.cannotComplete, nil) }
                          if wrote && rejectNextRead { rejectNextRead = false; return (.cannotComplete, nil) }
                          return (.success, frames[id]?.origin)
                      },
                      readSize: { [self] id, _ in (.success, frames[id]?.size) },
                      now: { [self] in now }, sleep: { [self] in now += $0 }, currentGeneration: generation)
        io.endFrameWrite = { [self] _, _, _ -> AXFrameWriteBatch.EndResult in
            guard let endError else { return .restored }
            return .failed(endError)
        }
        return io
    }
}

private final class MembershipTestScreen: NSScreen {
    override var frame: NSRect { NSRect(x: 4000, y: 0, width: 1600, height: 1000) }
    override var visibleFrame: NSRect { frame }
}
