import XCTest
import Cocoa
@testable import HyprMac

// pins TilingEngine.forceInsertWindow, the float→tile entry point. It works on
// a private candidate and reports a typed result, so a caller can tell a tiled
// window from an evicted neighbour from an outright refusal — the old optional
// return said "no eviction" and "nothing happened" with the same nil.

final class ForceInsertWindowFallbackTests: XCTestCase {

    private var displayManager: DisplayManager!
    private var engine: TilingEngine!
    private var screen: NSScreen!

    override func setUpWithError() throws {
        displayManager = DisplayManager()
        engine = TilingEngine(displayManager: displayManager,
                              frameSizingIOFactory: acceptingFrameSizingIOFactory())
        // tests need a real NSScreen — skip if the test runner has none (headless CI).
        guard let main = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("no NSScreen available — test requires a display")
        }
        screen = main
    }

    private func tree() -> BSPTree? {
        engine.existingTree(forWorkspace: 1, screen: screen)
    }

    // MARK: - empty tree

    func testForceInsertOnEmptyTreeFillsRoot() {
        let w = makeWindow(id: 1)
        XCTAssertEqual(engine.forceInsertWindow(w, toWorkspace: 1, on: screen), .inserted)
        XCTAssertEqual(tree()?.allWindows.map(\.windowID), [1])
        XCTAssertTrue(tree()?.root.isLeaf ?? false)
    }

    // MARK: - already in tree

    func testForceInsertAlreadyContainedReportsAlreadyPresentAndDoesNothing() {
        let w = makeWindow(id: 1)
        engine.forceInsertWindow(w, toWorkspace: 1, on: screen)
        XCTAssertEqual(tree()?.allWindows.count, 1)

        XCTAssertEqual(engine.forceInsertWindow(w, toWorkspace: 1, on: screen), .alreadyPresent)
        XCTAssertEqual(tree()?.allWindows.map(\.windowID), [1])
    }

    // MARK: - primary path: smartInsertFitting succeeds

    func testForceInsertSucceedsWithoutEvictionWhenSpaceAllows() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        engine.forceInsertWindow(w1, toWorkspace: 1, on: screen)

        XCTAssertEqual(engine.forceInsertWindow(w2, toWorkspace: 1, on: screen), .inserted)
        XCTAssertEqual(Set(tree()?.allWindows.map(\.windowID) ?? []), [1, 2])
    }

    // MARK: - path A: smartInsertFitting succeeds after eviction

    func testForceInsertEvictsAndReinsertsWhenAtMaxDepth() {
        // shrink maxDepth to force the smartInsertFitting precondition (depth < maxDepth) to fail.
        // with maxDepth=1, tree fills at 2 leaves (depth 1 each); a 3rd insert via
        // smartInsertFitting fails the depth check, triggering eviction.
        engine.maxSplitsPerMonitor[screen.localizedName] = 1

        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)
        engine.forceInsertWindow(w1, toWorkspace: 1, on: screen)
        engine.forceInsertWindow(w2, toWorkspace: 1, on: screen)
        XCTAssertEqual(tree()?.allWindows.count, 2)

        // evict and reinsert path: w2 (deepest-right) is evicted, w3 takes its slot.
        XCTAssertEqual(engine.forceInsertWindow(w3, toWorkspace: 1, on: screen), .evicted(2))
        XCTAssertEqual(Set(tree()?.allWindows.map(\.windowID) ?? []), [1, 3])
    }

    // MARK: - path B: smartInsertFitting STILL fails after eviction

    func testForceInsertReportsFailureAndKeepsTheEvictedWindowWhenIncomingDoesNotFit() {
        // even after eviction, smartInsertFitting can fail when the incoming
        // window's min-size exceeds the available rect. The candidate is
        // discarded whole, so the window that would have been evicted never
        // left the live tree and needs no reinsertion.
        engine.maxSplitsPerMonitor[screen.localizedName] = 1

        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        engine.forceInsertWindow(w1, toWorkspace: 1, on: screen)
        engine.forceInsertWindow(w2, toWorkspace: 1, on: screen)
        let before = tree()?.structuralFingerprint()

        let w3 = makeWindow(id: 3)
        w3.observedMinSize = CGSize(width: 100_000, height: 100_000)

        XCTAssertEqual(engine.forceInsertWindow(w3, toWorkspace: 1, on: screen),
                       .failed(.noFittingSlot))
        XCTAssertEqual(Set(tree()?.allWindows.map(\.windowID) ?? []), [1, 2])
        XCTAssertEqual(tree()?.structuralFingerprint(), before)
        XCTAssertFalse(tree()?.contains(w3) ?? true)
    }

    // MARK: - the screen refuses the layout

    func testRefusedLayoutKeepsTheOldTreeAndDoesNotCommitTheEviction() throws {
        let trace = ForceInsertTrace()
        let engine = TilingEngine(displayManager: DisplayManager(),
                                  frameSizingIOFactory: { _, generation in trace.io(generation) })
        engine.maxSplitsPerMonitor[screen.localizedName] = 1
        let w1 = makeWindow(id: 401)
        let w2 = makeWindow(id: 402)
        let usable = engine.displayManager.cgRect(for: screen)
        for (index, window) in [w1, w2].enumerated() {
            trace.frames[window.windowID] = CGRect(x: usable.minX + 20 + CGFloat(index) * 150,
                                                   y: usable.minY + 20, width: 120, height: 120)
        }
        XCTAssertEqual(engine.forceInsertWindow(w1, toWorkspace: 1, on: screen), .inserted)
        XCTAssertEqual(engine.forceInsertWindow(w2, toWorkspace: 1, on: screen), .inserted)
        let live = try XCTUnwrap(engine.existingTree(forWorkspace: 1, screen: screen))
        let before = live.structuralFingerprint()

        // the layout that would replace the evicted tile is refused
        let w3 = makeWindow(id: 403)
        trace.frames[w3.windowID] = CGRect(x: usable.minX + 20, y: usable.minY + 20,
                                           width: 120, height: 120)
        trace.rejectReadsFor = [w1.windowID]

        let result = engine.forceInsertWindow(w3, toWorkspace: 1, on: screen)

        guard case .failed(.layoutRejected) = result else {
            return XCTFail("expected a layout refusal, got \(result)")
        }
        XCTAssertEqual(engine.existingTree(forWorkspace: 1, screen: screen)?.structuralFingerprint(),
                       before, "the old tree survives, eviction included")
        XCTAssertEqual(Set(engine.windowIDs(inTreeForWorkspace: 1, screen: screen)), [401, 402])
    }
}

/// Minimal AX stand-in: setters land, reads answer with what landed, and
/// named windows can be made unreadable once a write has gone out.
private final class ForceInsertTrace {
    var frames: [CGWindowID: CGRect] = [:]
    var rejectReadsFor: Set<CGWindowID> = []
    private var wrote = false
    private var now: TimeInterval = 0

    func io(_ generation: @escaping () -> UInt64) -> FrameSizingIO {
        FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { [self] id, size, _ in wrote = true; frames[id]?.size = size; return .success },
            writePosition: { [self] id, position, _ in wrote = true; frames[id]?.origin = position; return .success },
            readPosition: { [self] id, _ in
                if wrote && rejectReadsFor.contains(id) { return (.cannotComplete, nil) }
                return (.success, frames[id]?.origin)
            },
            readSize: { [self] id, _ in (.success, frames[id]?.size) },
            now: { [self] in now }, sleep: { [self] in now += $0 },
            currentGeneration: generation)
    }
}
