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

    func testDegradedLayoutWithoutAttemptedRestorationPublishesCandidateMembership() throws {
        let f = try fixture()
        // originals parked off the usable frame, so restoration cannot be
        // attempted after the candidate readback fails — the writes stand
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        for window in f.windows {
            f.trace.frames[window.windowID] = CGRect(x: usable.maxX + 200, y: usable.minY + 20,
                                                     width: 120, height: 120)
        }
        f.trace.rejectNextRead = true

        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        let published = f.engine.existingTree(forWorkspace: 1, screen: f.screen)
        XCTAssertEqual(Set(published?.allWindows.map(\.windowID) ?? []), Set(f.windows.map(\.windowID)))
    }

    func testDegradedLayoutWithoutRestorationPublishesTheAdjustedRatios() throws {
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
        XCTAssertEqual(Set(published.allWindows.map(\.windowID)), Set(f.windows.map(\.windowID)))
        let layout = Dictionary(uniqueKeysWithValues: published.layout(
            in: usable, gap: f.engine.gapSize, padding: f.engine.outerPadding
        ).map { ($0.0.windowID, $0.1) })
        XCTAssertEqual(layout, f.trace.requested,
                       "the published tree must reproduce the frames left on screen")
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
    var onWrite: (() -> Void)?
    /// floor a window refuses to shrink below, the way a real min-size app behaves
    var minSize: [CGWindowID: CGSize] = [:]
    /// the frames the engine asked for, before any floor is applied
    var requested: [CGWindowID: CGRect] = [:]
    private var wrote = false
    private var now: TimeInterval = 0

    func io(_ generation: @escaping () -> UInt64) -> FrameSizingIO {
        FrameSizingIO(setMessagingTimeout: { _, _ in .success },
                      writeSize: { [self] id, size, _ in
                          onWrite?(); wrote = true
                          requested[id, default: .zero].size = size
                          let floor = minSize[id] ?? .zero
                          frames[id]?.size = CGSize(width: max(size.width, floor.width),
                                                    height: max(size.height, floor.height))
                          return .success
                      },
                      writePosition: { [self] id, position, _ in
                          onWrite?()
                          requested[id, default: .zero].origin = position
                          frames[id]?.origin = position
                          return .success
                      },
                      readPosition: { [self] id, _ in
                          if wrote && rejectNextRead { rejectNextRead = false; return (.cannotComplete, nil) }
                          return (.success, frames[id]?.origin)
                      },
                      readSize: { [self] id, _ in (.success, frames[id]?.size) },
                      now: { [self] in now }, sleep: { [self] in now += $0 }, currentGeneration: generation)
    }
}

private final class MembershipTestScreen: NSScreen {
    override var frame: NSRect { NSRect(x: 4000, y: 0, width: 1600, height: 1000) }
    override var visibleFrame: NSRect { frame }
}
