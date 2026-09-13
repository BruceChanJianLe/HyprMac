import Cocoa
import XCTest
@testable import HyprMac

/// The geometry half of directional focus and swap. `focusInDirection`
/// itself needs the whole dispatcher graph, so what is pinned here is the
/// engine's rect source, the one expression the dispatcher builds its
/// `frameFor` closure from, and the picker both hand it to.
final class DirectionalFocusGeometryTests: XCTestCase {
    func testUnverifiedKeyOffersNoIntendedRects() throws {
        let f = try fixture()

        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)
        XCTAssertEqual(Set(f.engine.intendedTileRects().keys), Set(f.windows.map(\.windowID)))

        f.trace.rejectNextRead = true
        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        XCTAssertTrue(f.engine.intendedTileRects().isEmpty,
                      "a tree that could not verify its layout has no rect to offer")
    }

    func testFallbackFrameIsUsedForUnverifiedAndTreeAbsentWindows() {
        let intended: [CGWindowID: CGRect] = [7: CGRect(x: 0, y: 0, width: 100, height: 100)]
        let live = CGRect(x: 500, y: 0, width: 100, height: 100)

        XCTAssertEqual(DirectionalGeometry.frame(for: 7, intended: intended, actual: live),
                       intended[7])
        // unverified key: its windows are not in the map at all
        XCTAssertEqual(DirectionalGeometry.frame(for: 8, intended: [:], actual: live), live)
        // stranded newcomer: visible, assigned, in no tree
        XCTAssertEqual(DirectionalGeometry.frame(for: 9, intended: intended, actual: live), live)
        XCTAssertNil(DirectionalGeometry.frame(for: 9, intended: intended, actual: nil))
    }

    func testDirectionalPickUsesActualFramesForAnUnverifiedKey() throws {
        let f = try fixture()
        let accessibility = AccessibilityManager()
        // the left window claims a wide intended rect; on screen it is
        // narrow, and the right window sits where the tree says nothing
        let left = StubFrameWindow(id: 41, frame: CGRect(x: 0, y: 0, width: 200, height: 400))
        let right = StubFrameWindow(id: 42, frame: CGRect(x: 300, y: 0, width: 200, height: 400))

        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)
        f.trace.rejectNextRead = true
        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)
        let intended = f.engine.intendedTileRects()
        let frameFor: (HyprWindow) -> CGRect? = {
            DirectionalGeometry.frame(for: $0.windowID, intended: intended, actual: $0.frame)
        }

        let target = accessibility.windowInDirection(.right, from: left, among: [left, right],
                                                     frameFor: frameFor)
        XCTAssertEqual(target?.windowID, 42)
    }

    func testVisibleTreeAbsentWindowStaysAFocusCandidate() {
        let accessibility = AccessibilityManager()
        let tiled = StubFrameWindow(id: 51, frame: CGRect(x: 0, y: 0, width: 200, height: 400))
        let stranded = StubFrameWindow(id: 52, frame: CGRect(x: 300, y: 0, width: 200, height: 400))
        // only the tiled window is in a tree
        let intended: [CGWindowID: CGRect] = [51: CGRect(x: 0, y: 0, width: 200, height: 400)]
        let frameFor: (HyprWindow) -> CGRect? = {
            DirectionalGeometry.frame(for: $0.windowID, intended: intended, actual: $0.frame)
        }

        let target = accessibility.windowInDirection(.right, from: tiled, among: [tiled, stranded],
                                                     frameFor: frameFor)
        XCTAssertEqual(target?.windowID, 52,
                       "a window missing from every tree is still somewhere to focus")
    }

    private func fixture() throws
        -> (engine: TilingEngine, windows: [HyprWindow], screen: NSScreen, trace: GeometryTrace) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("requires display geometry")
        }
        let windows = (941...942).map { id in
            HyprWindow(element: AXUIElementCreateApplication(99998), windowID: CGWindowID(id),
                       ownerPID: 99998)
        }
        let trace = GeometryTrace()
        let engine = TilingEngine(displayManager: DisplayManager(),
                                  frameSizingIOFactory: { _, generation in trace.io(generation) })
        let usable = engine.displayManager.cgRect(for: screen)
        for (index, window) in windows.enumerated() {
            trace.frames[window.windowID] = CGRect(x: usable.minX + 20 + CGFloat(index) * 150,
                                                   y: usable.minY + 20, width: 120, height: 120)
        }
        return (engine, windows, screen, trace)
    }
}

/// A window whose frame is whatever the test says it is. `HyprWindow.frame`
/// is a live AX read, and the picker has to be handed real geometry.
private final class StubFrameWindow: HyprWindow {
    private let stub: CGRect

    init(id: CGWindowID, frame: CGRect) {
        stub = frame
        super.init(element: AXUIElementCreateApplication(99997), windowID: id, ownerPID: 99997)
    }

    override var frame: CGRect? { stub }
}

private final class GeometryTrace {
    var frames: [CGWindowID: CGRect] = [:]
    var rejectNextRead = false
    private var wrote = false
    private var now: TimeInterval = 0

    func io(_ generation: @escaping () -> UInt64) -> FrameSizingIO {
        FrameSizingIO(setMessagingTimeout: { _, _ in .success },
                      writeSize: { [self] id, size, _ in
                          wrote = true
                          frames[id]?.size = size
                          return .success
                      },
                      writePosition: { [self] id, position, _ in
                          frames[id]?.origin = position
                          return .success
                      },
                      readPosition: { [self] id, _ in
                          if wrote && rejectNextRead { rejectNextRead = false; return (.cannotComplete, nil) }
                          return (.success, frames[id]?.origin)
                      },
                      readSize: { [self] id, _ in (.success, frames[id]?.size) },
                      now: { [self] in now }, sleep: { [self] in now += $0 },
                      currentGeneration: generation)
    }
}
