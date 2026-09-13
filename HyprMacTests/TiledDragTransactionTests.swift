import XCTest
@testable import HyprMac

final class TiledDragTransactionTests: XCTestCase {
    private final class FakeAX {
        var frames: [CGWindowID: CGRect]
        var generation: UInt64 = 1
        var writes: [(CGWindowID, CGRect)] = []
        var reads = 0
        var readIDs: [CGWindowID] = []
        var readError: AXError?
        var time: TimeInterval = 0
        var callAdvance: TimeInterval = 0
        var writeErrors: [AXError] = []
        var readErrors: [AXError] = []
        var onWrite: (() -> Void)?
        var forcedSizes: [CGSize] = []
        var sizeUndershoot: CGFloat = 0
        var readDrift: CGFloat = 0
        var readNumber: CGFloat = 0

        init(frames: [CGWindowID: CGRect]) { self.frames = frames }

        func factory(windows: [CGWindowID: HyprWindow], current: @escaping () -> UInt64) -> FrameSizingIO {
            var pendingSizes: [CGWindowID: CGSize] = [:]
            return FrameSizingIO(
                setMessagingTimeout: { _, _ in .success },
                writeSize: { [unowned self] id, size, _ in
                    onWrite?()
                    if !writeErrors.isEmpty {
                        let error = writeErrors.removeFirst()
                        if error != .success { return error }
                    }
                    pendingSizes[id] = size
                    frames[id]?.size = forcedSizes.isEmpty
                        ? CGSize(width: size.width - sizeUndershoot, height: size.height)
                        : forcedSizes.removeFirst()
                    writes.append((id, frames[id] ?? CGRect(origin: .zero, size: size)))
                    return .success
                },
                writePosition: { [unowned self] id, point, _ in
                    onWrite?()
                    if !writeErrors.isEmpty {
                        let error = writeErrors.removeFirst()
                        if error != .success { return error }
                    }
                    frames[id]?.origin = point
                    if let size = pendingSizes[id] { frames[id]?.size = size }
                    writes.append((id, frames[id] ?? CGRect(origin: point, size: .zero)))
                    return .success
                },
                readPosition: { [unowned self] id, _ in
                    reads += 1
                    readIDs.append(id)
                    time += callAdvance
                    if let readError { return (readError, nil) }
                    if !readErrors.isEmpty {
                        let error = readErrors.removeFirst()
                        if error != .success { return (error, nil) }
                    }
                    guard var origin = frames[id]?.origin else { return (.invalidUIElement, nil) }
                    readNumber += 1
                    origin.x += readDrift * readNumber
                    return (.success, origin)
                },
                readSize: { [unowned self] id, _ in
                    reads += 1
                    readIDs.append(id)
                    time += callAdvance
                    if let readError { return (readError, nil) }
                    if !readErrors.isEmpty {
                        let error = readErrors.removeFirst()
                        if error != .success { return (error, nil) }
                    }
                    return (.success, frames[id]?.size)
                },
                now: { [unowned self] in time },
                sleep: { [unowned self] interval in time += interval },
                currentGeneration: current
            )
        }
    }

    private func fixture(maxDepth: Int = 3) -> (BSPTree, [CGWindowID: HyprWindow], TiledDragContext) {
        let tree = BSPTree()
        let windows = [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)]
        windows.forEach { _ = tree.insert($0, maxDepth: 4) }
        let context = TiledDragContext(
            workspace: 1, physicalDisplayID: 77,
            usableFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            gap: 8, padding: 8, maxDepth: maxDepth,
            memberIDs: Set(windows.map(\.windowID)), floatingIDs: [],
            fingerprint: tree.structuralFingerprint())
        return (tree, Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) }), context)
    }

    func testCaptureUsesActualFramesOnceAndIsImmutable() {
        let (tree, windows, context) = fixture()
        let originals = Dictionary(uniqueKeysWithValues: tree.layout(in: context.usableFrame,
            gap: context.gap, padding: context.padding).map { ($0.0.windowID, $0.1) })
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        let result = transaction.capture(draggedID: 1, tree: tree, context: context,
                                         generation: 1, currentContext: { context })
        guard case let .captured(snapshot) = result else { return XCTFail("capture failed") }
        XCTAssertEqual(snapshot.originalFrames, originals)
        XCTAssertEqual(fake.reads, originals.count * 2)
        fake.frames[1] = .zero
        XCTAssertEqual(snapshot.originalFrames[1], originals[1])
        XCTAssertEqual(snapshot.originalTree.structuralFingerprint(), context.fingerprint)
        XCTAssertEqual(windows.count, 3)
    }

    func testCaptureReadFailureIsUnknownAndNeverWrites() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        fake.readError = .cannotComplete
        guard case .unknown = TiledDragTransaction(ioFactory: fake.factory).capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("failed read must be unknown") }
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testCaptureTimeoutIsUnknownAndNeverWrites() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        fake.callAdvance = 1
        guard case .unknown(.deadlineExceeded) = TiledDragTransaction(ioFactory: fake.factory).capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("slow capture must time out") }
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testCaptureStaleContextIsSupersededAndNeverWrites() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        guard case .unknown(.superseded) = TiledDragTransaction(ioFactory: fake.factory).capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { nil }) else { return XCTFail("stale capture must be superseded") }
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testCaptureFloatingWindowIsIneligibleAndNeverWrites() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let changed = replacing(context, floatingIDs: [1])
        guard case .ineligible(.floating) = TiledDragTransaction(ioFactory: fake.factory).capture(
            draggedID: 1, tree: tree, context: changed, generation: 1,
            currentContext: { changed }) else { return XCTFail("floating capture must be ineligible") }
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testCaptureScratchpadIsIneligibleAndNeverWrites() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let changed = replacing(context, workspace: TilingEngine.scratchpadWorkspace)
        guard case .ineligible(.scratchpad) = TiledDragTransaction(ioFactory: fake.factory).capture(
            draggedID: 1, tree: tree, context: changed, generation: 1,
            currentContext: { changed }) else { return XCTFail("scratchpad capture must be ineligible") }
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testPointerCaptureReadsTilesAndOccludersOnceAndPublishesCompleteFrames() {
        let (tree, _, context) = fixture()
        let occluder = makeWindow(id: 40)
        var frames = layoutFrames(tree, context)
        frames[40] = CGRect(x: 900, y: 700, width: 100, height: 50)
        let fake = FakeAX(frames: frames)
        var published: [CGWindowID: CGRect]?
        let result = TiledDragTransaction(ioFactory: fake.factory).capture(
            pointer: center(frames[1]!), tree: tree, context: context,
            occludingWindows: [occluder], generation: 1, currentContext: { context },
            onCapturedFrames: { published = $0 })
        XCTAssertEqual(published, frames)
        XCTAssertEqual(fake.reads, frames.count * 2)
        guard case let .captured(snapshot) = result else { return XCTFail("capture failed") }
        XCTAssertEqual(snapshot.draggedID, 1)
        XCTAssertEqual(snapshot.originalFrames, frames.filter { context.memberIDs.contains($0.key) })
    }

    func testPointerCapturePublishesCompleteFramesBeforeRejectingOccludedHit() {
        let (tree, _, context) = fixture()
        let occluder = makeWindow(id: 40)
        var frames = layoutFrames(tree, context)
        frames[40] = frames[1]
        let fake = FakeAX(frames: frames)
        var published: [CGWindowID: CGRect]?
        let result = TiledDragTransaction(ioFactory: fake.factory).capture(
            pointer: center(frames[1]!), tree: tree, context: context,
            occludingWindows: [occluder], generation: 1, currentContext: { context },
            onCapturedFrames: { published = $0 })
        XCTAssertEqual(published, frames)
        XCTAssertTrue(fake.writes.isEmpty)
        guard case .ineligible(.noTarget) = result else {
            return XCTFail("occluded tile must not be captured")
        }
    }

    func testPointerCaptureRejectsAmbiguousTileHit() {
        let (tree, _, context) = fixture()
        var frames = layoutFrames(tree, context)
        frames[2] = frames[1]
        let fake = FakeAX(frames: frames)
        guard case .ineligible(.noTarget) = TiledDragTransaction(ioFactory: fake.factory).capture(
            pointer: center(frames[1]!), tree: tree, context: context,
            occludingWindows: [], generation: 1, currentContext: { context }) else {
            return XCTFail("ambiguous tile hit must be rejected")
        }
    }

    func testPointerCaptureReadFailureIsUnknownAndDoesNotPublish() {
        let (tree, _, context) = fixture()
        let frames = layoutFrames(tree, context)
        let fake = FakeAX(frames: frames)
        fake.readError = .cannotComplete
        var published = false
        let result = TiledDragTransaction(ioFactory: fake.factory).capture(
            pointer: center(frames[1]!), tree: tree, context: context,
            occludingWindows: [], generation: 1, currentContext: { context },
            onCapturedFrames: { _ in published = true })
        guard case .unknown(.readFailed(_, .cannotComplete)) = result else {
            return XCTFail("failed combined read must be unknown")
        }
        XCTAssertFalse(published)
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testPointerCaptureRejectsNonfinitePointer() {
        let (tree, _, context) = fixture()
        let frames = layoutFrames(tree, context)
        let fake = FakeAX(frames: frames)
        guard case .ineligible(.noTarget) = TiledDragTransaction(ioFactory: fake.factory).capture(
            pointer: CGPoint(x: CGFloat.nan, y: 100), tree: tree, context: context,
            occludingWindows: [], generation: 1, currentContext: { context }) else {
            return XCTFail("nonfinite pointer must be rejected")
        }
        XCTAssertEqual(fake.reads, 0)
    }

    func testPointerCaptureRejectsFloatingContext() {
        let (tree, _, base) = fixture()
        let context = replacing(base, floatingIDs: [1])
        let fake = FakeAX(frames: layoutFrames(tree, context))
        guard case .ineligible(.floating) = TiledDragTransaction(ioFactory: fake.factory).capture(
            pointer: CGPoint(x: 100, y: 100), tree: tree, context: context,
            occludingWindows: [], generation: 1, currentContext: { context }) else {
            return XCTFail("floating context must be rejected")
        }
        XCTAssertEqual(fake.reads, 0)
    }

    func testPointerCaptureRejectsScratchpadContext() {
        let (tree, _, base) = fixture()
        let context = replacing(base, workspace: TilingEngine.scratchpadWorkspace)
        let fake = FakeAX(frames: layoutFrames(tree, context))
        guard case .ineligible(.scratchpad) = TiledDragTransaction(ioFactory: fake.factory).capture(
            pointer: CGPoint(x: 100, y: 100), tree: tree, context: context,
            occludingWindows: [], generation: 1, currentContext: { context }) else {
            return XCTFail("scratchpad context must be rejected")
        }
        XCTAssertEqual(fake.reads, 0)
    }

    func testPointerCaptureRejectsDuplicateAcrossTilesAndOccludersBeforeReads() {
        let (tree, windows, context) = fixture()
        let frames = layoutFrames(tree, context)
        let fake = FakeAX(frames: frames)
        guard case .unknown(.duplicateWindowID(1)) = TiledDragTransaction(ioFactory: fake.factory).capture(
            pointer: center(frames[1]!), tree: tree, context: context,
            occludingWindows: [windows[1]!], generation: 1, currentContext: { context }) else {
            return XCTFail("duplicate tile and occluder ID must be rejected")
        }
        XCTAssertEqual(fake.reads, 0)
    }

    func testAcceptedInsertionReturnsCandidateWithoutMutatingOriginal() {
        let (tree, _, context) = fixture()
        let originals = Dictionary(uniqueKeysWithValues: tree.layout(in: context.usableFrame,
            gap: context.gap, padding: context.padding).map { ($0.0.windowID, $0.1) })
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1, currentContext: { context }) else {
            return XCTFail("capture failed")
        }
        guard case let .committed(candidate, _) = transaction.drop(
            snapshot, mode: .insert(targetID: 2, edge: .left), currentContext: { context }) else {
            return XCTFail("drop did not commit")
        }
        XCTAssertEqual(tree.structuralFingerprint(), context.fingerprint)
        XCTAssertNotEqual(candidate.structuralFingerprint(), context.fingerprint)
    }

    func testStaleContextPerformsNoWrites() {
        let (tree, _, context) = fixture()
        let originals = Dictionary(uniqueKeysWithValues: tree.layout(in: context.usableFrame,
            gap: context.gap, padding: context.padding).map { ($0.0.windowID, $0.1) })
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1, currentContext: { context }) else {
            return XCTFail("capture failed")
        }
        var stale = context
        stale = TiledDragContext(workspace: 2, physicalDisplayID: stale.physicalDisplayID,
            usableFrame: stale.usableFrame, gap: stale.gap, padding: stale.padding,
            maxDepth: stale.maxDepth, memberIDs: stale.memberIDs,
            floatingIDs: stale.floatingIDs, fingerprint: stale.fingerprint)
        XCTAssertSuperseded(transaction.drop(snapshot, mode: .insert(targetID: 2, edge: .right),
                                              currentContext: { stale }))
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testMaxDepthRejectsCandidateButVerifiesOriginalFrameRestoration() {
        let (tree, _, context) = fixture(maxDepth: 1)
        let originals = Dictionary(uniqueKeysWithValues: tree.layout(in: context.usableFrame,
            gap: context.gap, padding: context.padding).map { ($0.0.windowID, $0.1) })
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1, currentContext: { context }) else {
            return XCTFail("capture failed")
        }
        fake.frames[1]?.origin.x += 100
        _ = transaction.drop(snapshot, mode: .insert(targetID: 2, edge: .left), currentContext: { context })
        XCTAssertEqual(fake.writes.count, originals.count * 3,
                       "max-depth rejection may write only one resize-move-resize restoration per original")
        XCTAssertEqual(fake.frames, originals)
        XCTAssertEqual(tree.structuralFingerprint(), context.fingerprint)
    }

    func testNoTargetRestoresMovedWindowAndMissingCaptureDoesNoWrites() {
        let (tree, _, context) = fixture()
        let originals = Dictionary(uniqueKeysWithValues: tree.layout(in: context.usableFrame,
            gap: context.gap, padding: context.padding).map { ($0.0.windowID, $0.1) })
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1, currentContext: { context }) else {
            return XCTFail("capture failed")
        }
        fake.frames[1]?.origin.x += 100
        _ = transaction.drop(snapshot, mode: nil, currentContext: { context })
        XCTAssertEqual(fake.frames, originals)

        fake.writes.removeAll()
        fake.frames.removeValue(forKey: 2)
        guard case .unknown = transaction.capture(draggedID: 1, tree: tree, context: context,
                                                  generation: 1, currentContext: { context }) else {
            return XCTFail("missing frame must be unknown")
        }
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testInvalidTargetRestoresMovedWindow() {
        let (tree, _, context) = fixture()
        let originals = layoutFrames(tree, context)
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.frames[1]?.origin.x += 100
        guard case .rejectedRestored = transaction.drop(
            snapshot, mode: .insert(targetID: 99, edge: .left), currentContext: { context }) else {
            return XCTFail("invalid target must restore")
        }
        XCTAssertEqual(fake.frames, originals)
    }

    func testAcceptedLeftEdge() { assertAccepted(edge: .left) }
    func testAcceptedRightEdge() { assertAccepted(edge: .right) }
    func testAcceptedTopEdge() { assertAccepted(edge: .top) }
    func testAcceptedBottomEdge() { assertAccepted(edge: .bottom) }

    func testOptionSwapUsesCandidateAndPreservesSource() {
        let (tree, _, context) = fixture()
        let originalOrder = tree.allWindows.map(\.windowID)
        let originalFingerprint = tree.structuralFingerprint()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        guard case let .committed(candidate, _) = transaction.drop(
            snapshot, mode: .swap(targetID: 2), currentContext: { context }) else {
            return XCTFail("swap did not commit")
        }
        XCTAssertEqual(candidate.allWindows.map(\.windowID), [2, 1, 3])
        XCTAssertEqual(tree.allWindows.map(\.windowID), originalOrder)
        XCTAssertEqual(tree.structuralFingerprint(), originalFingerprint)
    }

    func testCandidateWriteFailureRestoresFramesAndLeavesSourceUntouched() {
        let (tree, _, context) = fixture()
        let originals = layoutFrames(tree, context)
        let fingerprint = tree.structuralFingerprint()
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.writeErrors = [.cannotComplete]
        let outcome = transaction.drop(snapshot, mode: .insert(targetID: 2, edge: .right),
                                       currentContext: { context })
        guard case .rejectedRestored = outcome else { return XCTFail("expected verified restore") }
        XCTAssertEqual(fake.frames, originals)
        XCTAssertEqual(tree.structuralFingerprint(), fingerprint)
    }

    func testRestorationReadFailureIsDegraded() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.writeErrors = [.cannotComplete]
        fake.readError = .cannotComplete
        guard case let .degraded(candidate, restoration, _, _) = transaction.drop(
            snapshot, mode: .insert(targetID: 2, edge: .right), currentContext: { context }) else {
            return XCTFail("expected degraded restoration")
        }
        XCTAssertNotNil(candidate)
        XCTAssertNotNil(restoration)
    }

    func testRestorationGeometryRejectionIsDegraded() {
        let (tree, _, context) = fixture()
        let originals = layoutFrames(tree, context)
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.writeErrors = [.cannotComplete]
        let wrong = CGSize(width: originals[1]!.width + 40, height: originals[1]!.height)
        fake.forcedSizes = [wrong, wrong] + tree.allWindows.dropFirst().flatMap {
            [originals[$0.windowID]!.size, originals[$0.windowID]!.size]
        }
        fake.callAdvance = 0.02
        guard case let .degraded(_, restoration, _, _) = transaction.drop(
            snapshot, mode: .insert(targetID: 2, edge: .right), currentContext: { context }) else {
            return XCTFail("expected degraded restoration")
        }
        guard case .geometryMismatch(1) = restoration else {
            return XCTFail("expected restoration geometry rejection")
        }
    }

    func testCandidateReadFailureRestoresOriginalFrames() {
        let (tree, _, context) = fixture()
        let originals = layoutFrames(tree, context)
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.readErrors = [.cannotComplete]
        guard case .rejectedRestored = transaction.drop(
            snapshot, mode: .insert(targetID: 2, edge: .right),
            currentContext: { context }) else { return XCTFail("expected verified restore") }
        XCTAssertEqual(fake.frames, originals)
    }

    func testContextChangeDuringAXDoesNotWriteOriginalFrames() {
        let (tree, _, context) = fixture()
        let originals = layoutFrames(tree, context)
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        var live: TiledDragContext? = context
        var changed = false
        fake.onWrite = {
            guard !changed else { return }
            changed = true
            live = nil
        }
        fake.writes.removeAll()
        XCTAssertTrue(isSuperseded(transaction.drop(
            snapshot, mode: .insert(targetID: 2, edge: .left),
            currentContext: { live })))
        XCTAssertFalse(fake.writes.contains { originals[$0.0] == $0.1 },
                       "superseded candidate must not roll back old frames")
    }

    func testEveryContextDimensionInvalidatesWithoutWrites() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        let contexts = [
            contextCopy(context, workspace: 2),
            contextCopy(context, displayID: 78),
            contextCopy(context, usableFrame: context.usableFrame.insetBy(dx: 1, dy: 0)),
            contextCopy(context, gap: context.gap + 1),
            contextCopy(context, padding: context.padding + 1),
            contextCopy(context, maxDepth: context.maxDepth + 1),
            contextCopy(context, memberIDs: [1, 2]),
            contextCopy(context, floatingIDs: [3]),
            contextCopy(context, fingerprint: .init(nodes: []))
        ]
        fake.writes.removeAll()
        for changed in contexts {
            XCTAssertTrue(isSuperseded(transaction.drop(
                snapshot, mode: .insert(targetID: 2, edge: .left), currentContext: { changed })))
        }
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testLiveSourceMutationInvalidatesEvenWhenResolverReturnsCapturedContext() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        _ = tree.insert(makeWindow(id: 99), maxDepth: 5)
        fake.writes.removeAll()
        XCTAssertTrue(isSuperseded(transaction.drop(
            snapshot, mode: .insert(targetID: 2, edge: .left), currentContext: { context })))
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testOptionSwapOverCurrentMaxDepthRestoresWithoutCandidateWrites() {
        let (tree, _, base) = fixture()
        let context = contextCopy(base, maxDepth: 1)
        let originals = layoutFrames(tree, context)
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.writes.removeAll()
        guard case .rejectedRestored = transaction.drop(
            snapshot, mode: .swap(targetID: 2), currentContext: { context }) else {
            return XCTFail("over-depth swap must restore")
        }
        XCTAssertEqual(fake.writes.count, originals.count * 3)
        XCTAssertEqual(fake.frames, originals)
    }

    func testZeroGapTouchingAndFractionalGeometryAreAccepted() {
        let (tree, _, base) = fixture()
        tree.root.splitRatio = 1.0 / 3.0
        let context = contextCopy(base, usableFrame: CGRect(x: 0.25, y: 0.5,
            width: 1200.5, height: 800.25), gap: 0, fingerprint: tree.structuralFingerprint())
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        guard case .committed = transaction.drop(
            snapshot, mode: .swap(targetID: 2), currentContext: { context }) else {
            return XCTFail("touching fractional layout must be accepted")
        }
    }

    func testNeverSettledRestorationIsDegraded() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.readDrift = 2
        fake.readNumber = 0
        guard case let .degraded(_, restoration, _, _) = transaction.drop(
            snapshot, mode: nil, currentContext: { context }) else {
            return XCTFail("unsettled restoration must degrade")
        }
        XCTAssertEqual(restoration, .attemptsExhausted)
    }

    func testWindowMissingDuringCandidateIsDegraded() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.frames.removeValue(forKey: 2)
        guard case let .degraded(candidate, restoration, _, _) = transaction.drop(
            snapshot, mode: .insert(targetID: 2, edge: .left), currentContext: { context }) else {
            return XCTFail("missing window must degrade")
        }
        XCTAssertNotNil(candidate)
        XCTAssertNotNil(restoration)
    }

    func testFourColumnCandidateAppliesThroughRealSizingTransaction() {
        let tree = BSPTree()
        let windows = (1...4).map { makeWindow(id: CGWindowID($0)) }
        windows.forEach { _ = tree.insert($0, maxDepth: 4) }
        forceHorizontal(tree.root)
        let context = TiledDragContext(
            workspace: 1, physicalDisplayID: 77,
            usableFrame: CGRect(x: 0, y: 0, width: 1600, height: 800),
            gap: 8, padding: 0, maxDepth: 4,
            memberIDs: Set(windows.map(\.windowID)), floatingIDs: [],
            fingerprint: tree.structuralFingerprint())
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        guard case let .committed(_, frames) = transaction.drop(
            snapshot, mode: .insert(targetID: 2, edge: .left), currentContext: { context }) else {
            return XCTFail("four-column candidate must commit")
        }
        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(Set(frames.values.map(\.minX)).count, 4)
    }

    func testDropReleaseReadsOnlyDraggedWindowAndCommitsResizeOverThreshold() {
        let (tree, _, context) = fixture()
        let originals = layoutFrames(tree, context)
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.frames[1]!.size.width += 21
        fake.reads = 0
        fake.readIDs.removeAll()
        var classificationReadIDs: [CGWindowID] = []
        fake.onWrite = {
            if classificationReadIDs.isEmpty { classificationReadIDs = fake.readIDs }
        }
        guard case let .committed(candidate, actualFrames) = transaction.dropRelease(
            snapshot, mode: nil, currentContext: { context }) else {
            return XCTFail("manual resize must commit a candidate")
        }
        XCTAssertEqual(classificationReadIDs, [1, 1],
                       "release classification reads only dragged position and size")
        XCTAssertEqual(actualFrames, fake.frames)
        XCTAssertNotEqual(candidate.structuralFingerprint(), context.fingerprint)
        XCTAssertEqual(tree.structuralFingerprint(), context.fingerprint)
    }

    func testDropReleaseAtThresholdUsesOrdinaryNoTargetRestoration() {
        let (tree, _, context) = fixture()
        let originals = layoutFrames(tree, context)
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.frames[1]!.size.width += 20
        guard case .rejectedRestored(reason: .preflight(.noTarget), _) = transaction.dropRelease(
            snapshot, mode: nil, currentContext: { context }) else {
            return XCTFail("threshold-sized change must use ordinary drop")
        }
        XCTAssertEqual(fake.frames, originals)
    }

    func testNoTargetRestorationRejectsCellQuantizedUndershoot() throws {
        let (tree, _, context) = fixture()
        let originals = layoutFrames(tree, context)
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        var moved = try XCTUnwrap(fake.frames[1])
        moved.origin.x += 2
        fake.frames[1] = moved
        fake.sizeUndershoot = 6

        guard case let .degraded(candidateReason, restorationReason, actualFrames, _) =
                transaction.dropRelease(snapshot, mode: nil, currentContext: { context }) else {
            return XCTFail("inexact restoration must be degraded")
        }
        XCTAssertEqual(candidateReason, .preflight(.noTarget))
        XCTAssertEqual(restorationReason, .geometryMismatch(1))
        XCTAssertEqual(actualFrames[1]?.width, originals[1].map { $0.width - 6 })
    }

    func testDropReleaseClassificationReadFailureRestoresOriginals() {
        let (tree, _, context) = fixture()
        let originals = layoutFrames(tree, context)
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.frames[1]!.size.width += 40
        fake.readErrors = [.cannotComplete]
        guard case .rejectedRestored(reason: .sizing(.readFailed(1, .cannotComplete)), _) =
                transaction.dropRelease(snapshot, mode: nil, currentContext: { context }) else {
            return XCTFail("classification failure must be reported after restoration")
        }
        XCTAssertEqual(fake.frames, originals)
    }

    func testDropReleaseStaleContextDoesNoReadsOrWrites() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.reads = 0
        fake.writes.removeAll()
        XCTAssertTrue(isSuperseded(transaction.dropRelease(
            snapshot, mode: nil, currentContext: { nil })))
        XCTAssertEqual(fake.reads, 0)
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testValidatorAllowsNumericalSlackInsideGapEpsilonButRejectsOutside() {
        let targets = [
            FrameSizingAttempt.Target(windowID: 1,
                frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            FrameSizingAttempt.Target(windowID: 2,
                frame: CGRect(x: 108, y: 0, width: 100, height: 100))
        ]
        let fake = FakeAX(frames: [:])
        let attempt = FrameSizingAttempt(io: fake.factory(windows: [:], current: { 1 }))
        var frames = Dictionary(uniqueKeysWithValues: targets.map { ($0.windowID, $0.frame) })
        // a 28 pt gap less the 20 pt cell allowance puts the floor at the
        // windows' own 8 pt separation, so only the epsilon is under test
        frames[2]!.origin.x -= 0.00005
        XCTAssertEqual(attempt.validateFrames(targets: targets, actualFrames: frames,
                                               usableFrame: CGRect(x: 0, y: 0, width: 300, height: 100),
                                               gap: 28).verdict, .accepted)
        frames[2]!.origin.x -= 0.00015
        XCTAssertEqual(attempt.validateFrames(targets: targets, actualFrames: frames,
                                               usableFrame: CGRect(x: 0, y: 0, width: 300, height: 100),
                                               gap: 28).verdict, .rejected(.gapViolation(1, 2)))
    }

    func testValidatorAcceptsOnePointPositionAndSizeButRejectsMore() {
        let target = FrameSizingAttempt.Target(windowID: 1,
            frame: CGRect(x: 10, y: 10, width: 100, height: 100))
        let fake = FakeAX(frames: [:])
        let attempt = FrameSizingAttempt(io: fake.factory(windows: [:], current: { 1 }))
        let usable = CGRect(x: 0, y: 0, width: 300, height: 300)
        let atBoundary = CGRect(x: 11, y: 10, width: 101, height: 100)
        XCTAssertEqual(attempt.validateFrames(targets: [target], actualFrames: [1: atBoundary],
                                               usableFrame: usable, gap: 0).verdict, .accepted)
        let beyond = CGRect(x: 11.0001, y: 10, width: 101.0001, height: 100)
        XCTAssertEqual(attempt.validateFrames(targets: [target], actualFrames: [1: beyond],
                                               usableFrame: usable, gap: 0).verdict,
                       .rejected(.geometryMismatch(1)))
    }

    func testValidatorRejectsOverlapBeyondTheCellAllowance() {
        let fake = FakeAX(frames: [:])
        let attempt = FrameSizingAttempt(io: fake.factory(windows: [:], current: { 1 }))
        func verdict(secondX: CGFloat) -> FrameSizingAttempt.Verdict {
            let targets = [
                FrameSizingAttempt.Target(windowID: 1,
                    frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
                FrameSizingAttempt.Target(windowID: 2,
                    frame: CGRect(x: secondX, y: 0, width: 100, height: 100))
            ]
            let frames = Dictionary(uniqueKeysWithValues: targets.map { ($0.windowID, $0.frame) })
            return attempt.validateFrames(targets: targets, actualFrames: frames,
                                          usableFrame: CGRect(x: 0, y: 0, width: 300, height: 100),
                                          gap: 0).verdict
        }
        // exactly one cell of overlap on both axes is the allowance
        XCTAssertEqual(verdict(secondX: 80), .accepted)
        XCTAssertEqual(verdict(secondX: 79.99999), .rejected(.overlap(1, 2)))
    }

    func testDropReleaseHeightChangeOverThresholdCommitsResize() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.frames[1]!.size.height += 21
        guard case let .committed(candidate, _) = transaction.dropRelease(
            snapshot, mode: .insert(targetID: 2, edge: .left),
            currentContext: { context }) else {
            return XCTFail("height-only manual resize must commit")
        }
        XCTAssertEqual(candidate.structuralFingerprint(), context.fingerprint,
                       "height delta must select resize rather than insertion")
    }

    func testResizeCandidateWriteRefusalRestoresPredragFrames() {
        let (tree, _, context) = fixture()
        let originals = layoutFrames(tree, context)
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.frames[1]!.size.width += 21
        fake.writeErrors = [.cannotComplete]
        guard case .rejectedRestored(reason: .sizing(.writeFailed(_, .cannotComplete)), _) =
                transaction.dropRelease(snapshot, mode: nil, currentContext: { context }) else {
            return XCTFail("resize refusal must restore originals")
        }
        XCTAssertEqual(fake.frames, originals)
        XCTAssertEqual(tree.structuralFingerprint(), context.fingerprint)
    }

    func testClassificationFailureSupersededDuringRollbackReturnsSuperseded() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.readErrors = [.cannotComplete]
        var current: TiledDragContext? = context
        fake.onWrite = { current = nil }
        XCTAssertTrue(isSuperseded(transaction.dropRelease(
            snapshot, mode: nil, currentContext: { current })))
    }

    func testDropReleaseIgnoresContentDragWhenWindowDidNotMove() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.writes.removeAll()
        guard case .ignored = transaction.dropRelease(
            snapshot, mode: .insert(targetID: 2, edge: .left),
            currentContext: { context }) else {
            return XCTFail("content drag without window movement must be ignored")
        }
        XCTAssertTrue(fake.writes.isEmpty)
        XCTAssertEqual(tree.structuralFingerprint(), context.fingerprint)
    }

    func testDropReleaseIgnoresMovementAtPositionAndSizeTolerance() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.frames[1]!.origin.x += 1
        fake.frames[1]!.origin.y -= 1
        fake.frames[1]!.size.width += 1
        fake.frames[1]!.size.height -= 1
        guard case .ignored = transaction.dropRelease(
            snapshot, mode: .insert(targetID: 2, edge: .left),
            currentContext: { context }) else {
            return XCTFail("movement at configured tolerance must be ignored")
        }
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testDropReleaseTwoPointMovementStillAppliesShortDragInsertion() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.frames[1]!.origin.x += 2
        guard case .committed = transaction.dropRelease(
            snapshot, mode: .insert(targetID: 2, edge: .left),
            currentContext: { context }) else {
            return XCTFail("two-point actual movement must apply insertion")
        }
        XCTAssertFalse(fake.writes.isEmpty)
    }

    private func XCTAssertSuperseded(_ outcome: TiledDragDropOutcome,
                                     file: StaticString = #filePath, line: UInt = #line) {
        guard case .superseded = outcome else {
            return XCTFail("expected superseded", file: file, line: line)
        }
    }

    private func isSuperseded(_ outcome: TiledDragDropOutcome) -> Bool {
        if case .superseded = outcome { return true }
        return false
    }

    private func assertAccepted(edge: BSPTargetEdge, file: StaticString = #filePath,
                                line: UInt = #line) {
        let (tree, _, context) = fixture()
        let fingerprint = tree.structuralFingerprint()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else {
            return XCTFail("capture failed", file: file, line: line)
        }
        guard case let .committed(candidate, _) = transaction.drop(
            snapshot, mode: .insert(targetID: 2, edge: edge), currentContext: { context }) else {
            return XCTFail("edge did not commit", file: file, line: line)
        }
        XCTAssertEqual(tree.structuralFingerprint(), fingerprint, file: file, line: line)
        XCTAssertNotEqual(candidate.structuralFingerprint(), fingerprint, file: file, line: line)
    }

    private func layoutFrames(_ tree: BSPTree,
                              _ context: TiledDragContext) -> [CGWindowID: CGRect] {
        Dictionary(uniqueKeysWithValues: tree.layout(in: context.usableFrame,
            gap: context.gap, padding: context.padding).map { ($0.0.windowID, $0.1) })
    }

    private func replacing(_ context: TiledDragContext,
                           workspace: Int? = nil,
                           floatingIDs: Set<CGWindowID>? = nil) -> TiledDragContext {
        TiledDragContext(
            workspace: workspace ?? context.workspace,
            physicalDisplayID: context.physicalDisplayID,
            usableFrame: context.usableFrame,
            gap: context.gap,
            padding: context.padding,
            maxDepth: context.maxDepth,
            memberIDs: context.memberIDs,
            floatingIDs: floatingIDs ?? context.floatingIDs,
            fingerprint: context.fingerprint
        )
    }

    private func contextCopy(_ context: TiledDragContext,
                             workspace: Int? = nil,
                             displayID: CGDirectDisplayID? = nil,
                             usableFrame: CGRect? = nil,
                             gap: CGFloat? = nil,
                             padding: CGFloat? = nil,
                             maxDepth: Int? = nil,
                             memberIDs: Set<CGWindowID>? = nil,
                             floatingIDs: Set<CGWindowID>? = nil,
                             fingerprint: BSPTree.StructuralFingerprint? = nil) -> TiledDragContext {
        TiledDragContext(
            workspace: workspace ?? context.workspace,
            physicalDisplayID: displayID ?? context.physicalDisplayID,
            usableFrame: usableFrame ?? context.usableFrame,
            gap: gap ?? context.gap,
            padding: padding ?? context.padding,
            maxDepth: maxDepth ?? context.maxDepth,
            memberIDs: memberIDs ?? context.memberIDs,
            floatingIDs: floatingIDs ?? context.floatingIDs,
            fingerprint: fingerprint ?? context.fingerprint
        )
    }

    private func forceHorizontal(_ node: BSPNode) {
        guard !node.isLeaf else { return }
        node.splitOverride = .horizontal
        if let left = node.left { forceHorizontal(left) }
        if let right = node.right { forceHorizontal(right) }
    }

    private func center(_ frame: CGRect) -> CGPoint {
        CGPoint(x: frame.midX, y: frame.midY)
    }
}
