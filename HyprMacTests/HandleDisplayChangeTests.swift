import XCTest
import Cocoa
@testable import HyprMac

// HandleDisplayChangeTests cover the orphan-and-prune path of
// TilingEngine.handleDisplayChange. the migration path requires multiple live
// NSScreen instances and isn't exercised here — it's covered by the manual
// monitor-disconnect smoke test until we have a fake-display harness.
//
// see plan §4.2 (display lifecycle) + §11.

final class HandleDisplayChangeTests: XCTestCase {

    private var displayManager: DisplayManager!
    private var engine: TilingEngine!
    private var screen: NSScreen!

    override func setUpWithError() throws {
        displayManager = DisplayManager()
        engine = TilingEngine(displayManager: displayManager)
        guard let main = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("no NSScreen available — test requires a display")
        }
        screen = main
    }

    func testHandleDisplayChangePrunesOrphanedTrees() {
        // seed a tree
        engine.prepareTileLayout([makeWindow(id: 1), makeWindow(id: 2)],
                                 onWorkspace: 1, screen: screen)
        XCTAssertNotNil(engine.existingTree(forWorkspace: 1, screen: screen))

        // simulate the screen vanishing with no home-screen destination
        engine.handleDisplayChange(currentScreens: [], homeScreenForWorkspace: { _ in nil })

        // tree should be pruned
        XCTAssertNil(engine.existingTree(forWorkspace: 1, screen: screen))
    }

    func testAMigratedTreeCarriesItsUnverifiedMark() throws {
        let trace = MigrationTrace()
        let engine = TilingEngine(displayManager: DisplayManager(),
                                  frameSizingIOFactory: { _, generation in trace.io(generation) })
        let windows = (961...962).map {
            HyprWindow(element: AXUIElementCreateApplication(99996), windowID: CGWindowID($0),
                       ownerPID: 99996)
        }
        let usable = engine.displayManager.cgRect(for: screen)
        for (index, window) in windows.enumerated() {
            trace.frames[window.windowID] = CGRect(x: usable.minX + 20 + CGFloat(index) * 150,
                                                   y: usable.minY + 20, width: 120, height: 120)
        }
        engine.tileWindows(windows, onWorkspace: 1, screen: screen)
        XCTAssertFalse(engine.intendedTileRects().isEmpty)

        trace.rejectNextRead = true
        engine.tileWindows(windows, onWorkspace: 1, screen: screen)
        XCTAssertTrue(engine.intendedTileRects().isEmpty)

        // the workspace's home moves to a screen that is not in the manager's
        // live list, so the tree migrates and the claim has to go with it
        let destination = MigrationScreen()
        engine.handleDisplayChange(currentScreens: [screen, destination],
                                   homeScreenForWorkspace: { _ in destination })

        XCTAssertNotNil(engine.existingTree(forWorkspace: 1, screen: destination))
        XCTAssertEqual(engine.unverifiedGeometryWindowIDs, Set(windows.map(\.windowID)),
                       "a migrated tree has still never had a layout accepted")
    }

    func testHandleDisplayChangeIsNoopWhenTreeOnItsHome() {
        engine.prepareTileLayout([makeWindow(id: 1), makeWindow(id: 2)],
                                 onWorkspace: 1, screen: screen)
        let tree = engine.existingTree(forWorkspace: 1, screen: screen)
        XCTAssertNotNil(tree)
        let countBefore = tree?.allWindows.count

        // a tree already sitting on its workspace's current home is left alone.
        // (a nil home means "no live home" and prunes — covered above.)
        engine.handleDisplayChange(currentScreens: [screen], homeScreenForWorkspace: { _ in self.screen })

        XCTAssertNotNil(engine.existingTree(forWorkspace: 1, screen: screen))
        XCTAssertEqual(engine.existingTree(forWorkspace: 1, screen: screen)?.allWindows.count, countBefore)
    }
}

private final class MigrationScreen: NSScreen {
    override var frame: NSRect { NSRect(x: 6000, y: 0, width: 1400, height: 900) }
    override var visibleFrame: NSRect { frame }
}

private final class MigrationTrace {
    var frames: [CGWindowID: CGRect] = [:]
    var rejectNextRead = false
    private var wrote = false
    private var now: TimeInterval = 0

    func io(_ generation: @escaping () -> UInt64) -> FrameSizingIO {
        FrameSizingIO(setMessagingTimeout: { _, _ in .success },
                      writeSize: { [self] id, size, _ in wrote = true; frames[id]?.size = size; return .success },
                      writePosition: { [self] id, position, _ in frames[id]?.origin = position; return .success },
                      readPosition: { [self] id, _ in
                          if wrote && rejectNextRead { rejectNextRead = false; return (.cannotComplete, nil) }
                          return (.success, frames[id]?.origin)
                      },
                      readSize: { [self] id, _ in (.success, frames[id]?.size) },
                      now: { [self] in now }, sleep: { [self] in now += $0 },
                      currentGeneration: generation)
    }
}

final class DisplaySnapshotTests: XCTestCase {
    func testFingerprintRefreshesAChangedProviderWithoutNotification() {
        let first = SnapshotScreen()
        let second = SnapshotScreen()
        second.bounds.size.width = 1512
        var provided: [NSScreen] = [first]
        let manager = DisplayManager(screenSource: { provided })
        let before = manager.refreshedFingerprint()
        provided = [second]
        XCTAssertNotEqual(manager.refreshedFingerprint(), before)
        XCTAssertEqual(manager.screens.first?.frame.width, 1512)
    }

    func testOnePointUsableFrameNoiseKeepsTheSameFingerprint() {
        let screen = SnapshotScreen()
        let manager = DisplayManager(screenSource: { [screen] })
        let before = manager.refreshedFingerprint()
        screen.usable = screen.bounds.offsetBy(dx: 0, dy: 1)
        XCTAssertEqual(manager.refreshedFingerprint(), before)
        screen.usable = screen.bounds.offsetBy(dx: 0, dy: 2)
        XCTAssertNotEqual(manager.refreshedFingerprint(), before, "noise cannot accumulate against a moving anchor")
    }

    func testASymmetricOnePointInsetChangesTheFingerprint() {
        let screen = SnapshotScreen()
        let manager = DisplayManager(screenSource: { [screen] })
        let before = manager.refreshedFingerprint()
        // each edge moves one point, so every edge delta is inside the slack,
        // but the usable area is two points narrower
        screen.usable = screen.bounds.insetBy(dx: 1, dy: 0)
        XCTAssertNotEqual(manager.refreshedFingerprint(), before)
    }

    func testUsableBoundsAndPhysicalIdentityChangeTheFingerprint() {
        let screen = SnapshotScreen()
        let manager = DisplayManager(screenSource: { [screen] })
        let before = manager.refreshedFingerprint()
        screen.usable = screen.bounds.insetBy(dx: 0, dy: 25)
        let inset = manager.refreshedFingerprint()
        XCTAssertNotEqual(inset, before)
        screen.displayID = 42
        XCTAssertNotEqual(manager.refreshedFingerprint(), inset)
    }
}

private final class SnapshotScreen: NSScreen {
    var bounds = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    var usable: NSRect?
    var displayID = 41
    override var frame: NSRect { bounds }
    override var visibleFrame: NSRect { usable ?? bounds }
    override var localizedName: String { "Test display" }
    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): NSNumber(value: displayID)]
    }
}
