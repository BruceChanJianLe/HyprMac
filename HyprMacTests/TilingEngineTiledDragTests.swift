import Cocoa
import XCTest
@testable import HyprMac

final class TilingEngineTiledDragTests: XCTestCase {
    func testEmptyWorkspacePublishesCompleteOccluderFramesWithoutCreatingTree() throws {
        let fixture = try makeEmptyFixture()
        let occluders = [makeWindow(id: 40), makeWindow(id: 41)]
        fixture.trace.frames = [
            40: CGRect(x: 20, y: 30, width: 300, height: 200),
            41: CGRect(x: 400, y: 50, width: 250, height: 180)
        ]
        var published: [CGWindowID: CGRect]?

        let result = fixture.engine.captureTiledDrag(
            pointer: CGPoint(x: 30, y: 40), occludingWindows: occluders,
            currentLocation: { (1, fixture.screen, Set([40, 41])) },
            onCapturedFrames: { published = $0 })

        XCTAssertEqual(published, fixture.trace.frames)
        guard case .ineligible(.noTarget) = result else {
            return XCTFail("empty workspace must have no tiled target")
        }
        XCTAssertNil(fixture.engine.existingTree(forWorkspace: 1, screen: fixture.screen))
    }

    func testEmptyWorkspaceRejectsDuplicateOccludersBeforeReads() throws {
        let fixture = try makeEmptyFixture()
        let duplicate = makeWindow(id: 40)
        let result = fixture.engine.captureTiledDrag(
            pointer: .zero, occludingWindows: [duplicate, duplicate],
            currentLocation: { (1, fixture.screen, [40]) })

        XCTAssertEqual(fixture.trace.readCalls, 0)
        guard case .unknown(.duplicateWindowID(40)) = result else {
            return XCTFail("duplicate occluders must fail closed")
        }
    }

    func testEmptyWorkspaceReadFailureDoesNotPublishFrames() throws {
        let fixture = try makeEmptyFixture()
        let occluder = makeWindow(id: 40)
        fixture.trace.frames[40] = CGRect(x: 20, y: 30, width: 300, height: 200)
        fixture.trace.nextReadError = .cannotComplete
        var published = false

        let result = fixture.engine.captureTiledDrag(
            pointer: .zero, occludingWindows: [occluder],
            currentLocation: { (1, fixture.screen, [40]) },
            onCapturedFrames: { _ in published = true })

        XCTAssertFalse(published)
        guard case .unknown(.readFailed(40, .cannotComplete)) = result else {
            return XCTFail("occluder read failure must be unknown")
        }
    }

    func testEmptyWorkspaceContextChangeDuringReadDoesNotPublishFrames() throws {
        let fixture = try makeEmptyFixture()
        let occluder = makeWindow(id: 40)
        fixture.trace.frames[40] = CGRect(x: 20, y: 30, width: 300, height: 200)
        var floatingIDs: Set<CGWindowID> = [40]
        fixture.trace.onNextRead = { floatingIDs = [] }
        var published = false

        let result = fixture.engine.captureTiledDrag(
            pointer: .zero, occludingWindows: [occluder],
            currentLocation: { (1, fixture.screen, floatingIDs) },
            onCapturedFrames: { _ in published = true })

        XCTAssertGreaterThan(fixture.trace.readCalls, 0)
        XCTAssertFalse(published)
        guard case .unknown(.superseded) = result else {
            return XCTFail("stale occluder capture must be unknown")
        }
        XCTAssertNil(fixture.engine.existingTree(forWorkspace: 1, screen: fixture.screen))
    }

    func testUnchangedReleaseIsIgnoredWithoutWritesOrTreeReplacement() throws {
        let fixture = try makeFixture()
        let snapshot = try capture(fixture)
        let mapped = try XCTUnwrap(fixture.engine.existingTree(forWorkspace: 1,
                                                              screen: fixture.screen))
        fixture.trace.writes.removeAll()

        let outcome = fixture.engine.dropTiledDrag(
            snapshot, mode: .insert(targetID: 2, edge: .left),
            currentLocation: { (1, fixture.screen, []) })

        XCTAssertTrue(fixture.trace.writes.isEmpty)
        guard case .ignored = outcome else { return XCTFail("unchanged release must be ignored") }
        XCTAssertTrue(fixture.engine.existingTree(forWorkspace: 1,
                                                  screen: fixture.screen) === mapped)
    }

    func testReleaseWithoutTargetCommitsDetectedResize() throws {
        let fixture = try makeFixture()
        let snapshot = try capture(fixture)
        fixture.trace.frames[1]?.size.width += 30

        let outcome = fixture.engine.dropTiledDrag(
            snapshot, mode: nil, currentLocation: { (1, fixture.screen, []) })

        guard case let .committed(candidate, _, _) = outcome else {
            return XCTFail("detected resize must commit")
        }
        XCTAssertTrue(fixture.engine.existingTree(forWorkspace: 1,
                                                  screen: fixture.screen) === candidate)
    }

    func testResizeClassificationReadFailureRestoresOriginalFrameMap() throws {
        let fixture = try makeFixture()
        let snapshot = try capture(fixture)
        fixture.trace.frames[1]?.size.width += 30
        fixture.trace.nextReadError = .cannotComplete

        let outcome = fixture.engine.dropTiledDrag(
            snapshot, mode: nil, currentLocation: { (1, fixture.screen, []) })

        guard case .rejectedRestored(
            reason: .sizing(.readFailed(1, .cannotComplete)), _
        ) = outcome else {
            return XCTFail("classification error must report verified restoration")
        }
        XCTAssertEqual(fixture.trace.frames, snapshot.originalFrames)
    }

    func testPointerCapturePublishesExactCombinedFrames() throws {
        let fixture = try makeFixture()
        var published: [CGWindowID: CGRect]?
        let result = fixture.engine.captureTiledDrag(
            pointer: center(of: fixture.trace.frames[1]), occludingWindows: [],
            currentLocation: { (1, fixture.screen, []) },
            onCapturedFrames: { published = $0 })
        XCTAssertEqual(published, fixture.trace.frames)
        guard case .captured = result else { return XCTFail("expected pointer capture") }
    }

    func testPointerCaptureRechecksFloatingStateDuringReads() throws {
        let fixture = try makeFixture()
        var location: (workspace: Int, screen: NSScreen, floatingIDs: Set<CGWindowID>)?
            = (1, fixture.screen, [])
        fixture.trace.onNextRead = { location = (1, fixture.screen, [1]) }
        let result = fixture.engine.captureTiledDrag(
            pointer: center(of: fixture.trace.frames[1]), occludingWindows: [],
            currentLocation: { location })
        XCTAssertGreaterThan(fixture.trace.readCalls, 0)
        guard case .unknown(.superseded) = result else {
            return XCTFail("floating change must supersede capture")
        }
    }

    func testPointerCaptureRechecksRemovedLocationDuringReads() throws {
        let removed = try makeFixture()
        var current: (workspace: Int, screen: NSScreen, floatingIDs: Set<CGWindowID>)?
            = (1, removed.screen, [])
        removed.trace.onNextRead = { current = nil }
        let result = removed.engine.captureTiledDrag(
            pointer: center(of: removed.trace.frames[1]), occludingWindows: [],
            currentLocation: { current })
        XCTAssertGreaterThan(removed.trace.readCalls, 0)
        guard case .unknown(.superseded) = result else {
            return XCTFail("removed location must supersede capture")
        }
    }

    func testPointerCaptureRechecksPhysicalDisplayIdentityDuringReads() throws {
        var displayID: CGDirectDisplayID = 10
        let fixture = try makeFixture(selectedDisplayID: { displayID })
        fixture.trace.onNextRead = { displayID = 11 }
        let result = fixture.engine.captureTiledDrag(
            pointer: center(of: fixture.trace.frames[1]), occludingWindows: [],
            currentLocation: { (1, fixture.screen, []) })
        XCTAssertGreaterThan(fixture.trace.readCalls, 0)
        guard case .unknown(.superseded) = result else {
            return XCTFail("display replacement must supersede capture")
        }
    }

    func testPointerCaptureRechecksLayoutConfigurationDuringReads() throws {
        for change in 0..<3 {
            let fixture = try makeFixture()
            fixture.trace.onNextRead = {
                if change == 0 { fixture.engine.gapSize += 1 }
                if change == 1 { fixture.engine.outerPadding += 1 }
                if change == 2 { fixture.engine.maxSplitsPerMonitor[fixture.screen.localizedName] = 1 }
            }
            let result = fixture.engine.captureTiledDrag(
                pointer: center(of: fixture.trace.frames[1]), occludingWindows: [],
                currentLocation: { (1, fixture.screen, []) })
            XCTAssertGreaterThan(fixture.trace.readCalls, 0)
            if case .unknown(.superseded) = result {
                continue
            }
            XCTFail("configuration change \(change) must supersede capture")
        }
    }

    func testAcceptedDropReplacesMappedTreeOnlyAfterVerifiedFrames() throws {
        let fixture = try makeFixture()
        let oldTree = try XCTUnwrap(fixture.engine.existingTree(forWorkspace: 1,
                                                               screen: fixture.screen))
        let snapshot = try capture(fixture)
        fixture.trace.frames[1]?.origin.x += 2

        let outcome = fixture.engine.dropTiledDrag(
            snapshot, mode: .insert(targetID: 2, edge: .left),
            currentLocation: { (1, fixture.screen, []) })

        guard case let .committed(candidate, actualFrames, _) = outcome else {
            return XCTFail("expected committed drop")
        }
        let mapped = try XCTUnwrap(fixture.engine.existingTree(forWorkspace: 1,
                                                               screen: fixture.screen))
        XCTAssertFalse(mapped === oldTree)
        XCTAssertTrue(mapped === candidate)
        XCTAssertEqual(Set(actualFrames.keys), Set([1, 2, 3]))
    }

    func testChangedWorkspaceSupersedesWithoutReplacingTree() throws {
        let fixture = try makeFixture()
        let oldTree = try XCTUnwrap(fixture.engine.existingTree(forWorkspace: 1,
                                                               screen: fixture.screen))
        let snapshot = try capture(fixture)

        let outcome = fixture.engine.dropTiledDrag(
            snapshot, mode: .insert(targetID: 2, edge: .right),
            currentLocation: { (2, fixture.screen, []) })

        guard case .superseded = outcome else { return XCTFail("expected superseded") }
        XCTAssertTrue(fixture.engine.existingTree(forWorkspace: 1,
                                                  screen: fixture.screen) === oldTree)
        XCTAssertTrue(fixture.trace.writes.isEmpty)
    }

    func testGenerationChangeDuringAXSupersedesWithoutCommit() throws {
        let fixture = try makeFixture()
        let snapshot = try capture(fixture)
        let oldTree = try XCTUnwrap(fixture.engine.existingTree(forWorkspace: 1,
                                                               screen: fixture.screen))
        fixture.trace.frames[1]?.origin.x += 2
        fixture.trace.onNextWrite = { fixture.engine.beginLayoutGeneration() }

        let outcome = fixture.engine.dropTiledDrag(
            snapshot, mode: .insert(targetID: 2, edge: .left),
            currentLocation: { (1, fixture.screen, []) })

        guard case .superseded = outcome else { return XCTFail("expected superseded") }
        XCTAssertTrue(fixture.engine.existingTree(forWorkspace: 1,
                                                  screen: fixture.screen) === oldTree)
    }

    func testFloatingMembershipChangeSupersedesBeforeWrites() throws {
        let fixture = try makeFixture()
        let snapshot = try capture(fixture)
        fixture.trace.writes.removeAll()

        let outcome = fixture.engine.dropTiledDrag(
            snapshot, mode: .insert(targetID: 2, edge: .left),
            currentLocation: { (1, fixture.screen, [2]) })

        guard case .superseded = outcome else { return XCTFail("expected superseded") }
        XCTAssertTrue(fixture.trace.writes.isEmpty)
    }

    func testRejectedRestoredKeepsOriginalTree() throws {
        let fixture = try makeFixture()
        let snapshot = try capture(fixture)
        let oldTree = try XCTUnwrap(fixture.engine.existingTree(forWorkspace: 1,
                                                               screen: fixture.screen))
        fixture.trace.frames[1]?.origin.x += 2
        fixture.trace.remainingWriteFailures = 1

        let outcome = fixture.engine.dropTiledDrag(
            snapshot, mode: .insert(targetID: 2, edge: .left),
            currentLocation: { (1, fixture.screen, []) })

        guard case .rejectedRestored = outcome else {
            return XCTFail("expected verified restoration")
        }
        XCTAssertTrue(fixture.engine.existingTree(forWorkspace: 1,
                                                  screen: fixture.screen) === oldTree)
    }

    func testDegradedDropKeepsOriginalTree() throws {
        let fixture = try makeFixture()
        let snapshot = try capture(fixture)
        let oldTree = try XCTUnwrap(fixture.engine.existingTree(forWorkspace: 1,
                                                               screen: fixture.screen))
        fixture.trace.frames[1]?.origin.x += 2
        fixture.trace.remainingWriteFailures = 2

        let outcome = fixture.engine.dropTiledDrag(
            snapshot, mode: .insert(targetID: 2, edge: .left),
            currentLocation: { (1, fixture.screen, []) })

        guard case .degraded = outcome else { return XCTFail("expected degraded drop") }
        XCTAssertTrue(fixture.engine.existingTree(forWorkspace: 1,
                                                  screen: fixture.screen) === oldTree)
    }

    func testGenerationChangeDuringRestorationMapsEngineOutcomeToSuperseded() throws {
        let fixture = try makeFixture()
        let snapshot = try capture(fixture)
        fixture.trace.frames[1]?.origin.x += 2
        fixture.trace.remainingWriteFailures = 1
        fixture.trace.onWrite = { call in
            if call == 2 { fixture.engine.beginLayoutGeneration() }
        }
        let outcome = fixture.engine.dropTiledDrag(
            snapshot, mode: .insert(targetID: 2, edge: .left),
            currentLocation: { (1, fixture.screen, []) })
        guard case .superseded = outcome else {
            return XCTFail("stale restoration outcome must map to superseded")
        }
        XCTAssertEqual(fixture.trace.writeCalls, 2)
    }

    func testCleanupWrappedSupersessionMapsEngineOutcomeToSuperseded() throws {
        let fixture = try makeFixture()
        let snapshot = try capture(fixture)
        fixture.trace.frames[1]?.origin.x += 2
        fixture.trace.cleanupError = .cannotComplete
        fixture.trace.onNextWrite = { fixture.engine.beginLayoutGeneration() }
        let outcome = fixture.engine.dropTiledDrag(
            snapshot, mode: .insert(targetID: 2, edge: .left),
            currentLocation: { (1, fixture.screen, []) })
        guard case .superseded = outcome else {
            return XCTFail("cleanup-wrapped stale outcome must map to superseded")
        }
    }

    private struct Fixture {
        let engine: TilingEngine
        let screen: NSScreen
        let trace: DragSizingTrace
    }

    private func makeFixture(
        selectedDisplayID: (() -> CGDirectDisplayID)? = nil
    ) throws -> Fixture {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("tiled drag engine tests require a screen fixture")
        }
        let trace = DragSizingTrace()
        let fixtureDisplayID = (screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber)?.uint32Value ?? 0
        let displayID: (NSScreen) -> CGDirectDisplayID = { candidate in
            let actualID = (candidate.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber)?.uint32Value ?? 0
            if actualID == fixtureDisplayID, let selectedDisplayID { return selectedDisplayID() }
            return actualID
        }
        let engine = TilingEngine(displayManager: DisplayManager(),
                                  frameSizingIOFactory: trace.factory,
                                  tiledDragDisplayID: displayID)
        let windows = [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)]
        let layouts = engine.prepareTileLayout(windows, onWorkspace: 1, screen: screen)
        trace.frames = Dictionary(uniqueKeysWithValues: layouts.map { ($0.0.windowID, $0.1) })
        return Fixture(engine: engine, screen: screen, trace: trace)
    }

    private func makeEmptyFixture() throws -> Fixture {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("tiled drag engine tests require a screen fixture")
        }
        let trace = DragSizingTrace()
        let engine = TilingEngine(displayManager: DisplayManager(),
                                  frameSizingIOFactory: trace.factory)
        return Fixture(engine: engine, screen: screen, trace: trace)
    }

    private func capture(_ fixture: Fixture) throws -> TiledDragSnapshot {
        let result = fixture.engine.captureTiledDrag(draggedID: 1, workspace: 1,
                                                     screen: fixture.screen, floatingIDs: [])
        guard case let .captured(snapshot) = result else {
            throw TestFailure.capture
        }
        return snapshot
    }

    private enum TestFailure: Error { case capture }

    private func center(of frame: CGRect?) -> CGPoint {
        guard let frame else { return .zero }
        return CGPoint(x: frame.midX, y: frame.midY)
    }
}

private final class DragSizingTrace {
    var frames: [CGWindowID: CGRect] = [:]
    var writes: [CGWindowID] = []
    var onNextWrite: (() -> Void)?
    var onWrite: ((Int) -> Void)?
    var onNextRead: (() -> Void)?
    var remainingWriteFailures = 0
    var writeCalls = 0
    var cleanupError: AXError?
    var readCalls = 0
    var nextReadError: AXError?

    func factory(_ windows: [CGWindowID: HyprWindow],
                 _ generation: @escaping () -> UInt64) -> FrameSizingIO {
        FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { [unowned self] id, size, _ in
                writeCalls += 1
                onWrite?(writeCalls)
                onNextWrite?()
                onNextWrite = nil
                if remainingWriteFailures > 0 {
                    remainingWriteFailures -= 1
                    return .cannotComplete
                }
                frames[id]?.size = size
                writes.append(id)
                return .success
            },
            writePosition: { [unowned self] id, point, _ in
                writeCalls += 1
                onWrite?(writeCalls)
                frames[id]?.origin = point
                writes.append(id)
                return .success
            },
            readPosition: { [unowned self] id, _ in
                readCalls += 1
                onNextRead?()
                onNextRead = nil
                if let error = nextReadError {
                    nextReadError = nil
                    return (error, nil)
                }
                return (.success, frames[id]?.origin)
            },
            readSize: { [unowned self] id, _ in (.success, frames[id]?.size) },
            now: { 0 }, sleep: { _ in }, currentGeneration: generation,
            endFrameWrite: { [unowned self] _, _, _ in
                cleanupError.map { .failed($0) } ?? .restored
            }
        )
    }
}
