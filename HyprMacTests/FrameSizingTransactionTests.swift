import XCTest
@testable import HyprMac

final class FrameSizingTransactionTests: XCTestCase {
    private final class Fake {
        var time: TimeInterval = 0
        var generation: UInt64 = 1
        var frames: [CGWindowID: CGRect] = [:]
        var operations: [String] = []
        var reads: [CGWindowID: [(AXError, CGRect?)]] = [:]
        var sizeReads: [CGWindowID: [(AXError, CGSize?)]] = [:]
        var writeErrors: [AXError] = []
        var timeoutErrors: [AXError] = []
        var timeoutAdvances: [TimeInterval] = []
        var writeAdvances: [TimeInterval] = []
        var positionReadAdvances: [TimeInterval] = []
        var sizeReadAdvances: [TimeInterval] = []
        var callAdvance: TimeInterval = 0

        func io() -> FrameSizingIO {
            FrameSizingIO(
                setMessagingTimeout: { [unowned self] id, _ in
                    operations.append("timeout:\(id)")
                    time += timeoutAdvances.isEmpty ? callAdvance : timeoutAdvances.removeFirst()
                    if !timeoutErrors.isEmpty { return timeoutErrors.removeFirst() }
                    return .success
                },
                writeSize: { [unowned self] id, size, _ in
                    operations.append("size:\(id)")
                    time += writeAdvances.isEmpty ? callAdvance : writeAdvances.removeFirst()
                    if !writeErrors.isEmpty { return writeErrors.removeFirst() }
                    frames[id]?.size = size
                    return .success
                },
                writePosition: { [unowned self] id, point, _ in
                    operations.append("position:\(id)")
                    time += writeAdvances.isEmpty ? callAdvance : writeAdvances.removeFirst()
                    if !writeErrors.isEmpty { return writeErrors.removeFirst() }
                    frames[id]?.origin = point
                    return .success
                },
                readPosition: { [unowned self] id, _ in
                    operations.append("position-read:\(id)")
                    time += positionReadAdvances.isEmpty ? callAdvance : positionReadAdvances.removeFirst()
                    if var scripted = reads[id], !scripted.isEmpty {
                        let next = scripted.removeFirst()
                        reads[id] = scripted
                        return (next.0, next.1?.origin)
                    }
                    guard let frame = frames[id] else { return (.invalidUIElement, nil) }
                    return (.success, frame.origin)
                },
                readSize: { [unowned self] id, _ in
                    operations.append("size-read:\(id)")
                    time += sizeReadAdvances.isEmpty ? callAdvance : sizeReadAdvances.removeFirst()
                    if var scripted = sizeReads[id], !scripted.isEmpty {
                        let next = scripted.removeFirst()
                        sizeReads[id] = scripted
                        return next
                    }
                    guard let frame = frames[id] else { return (.invalidUIElement, nil) }
                    return (.success, frame.size)
                },
                now: { [unowned self] in time },
                sleep: { [unowned self] interval in time += interval },
                currentGeneration: { [unowned self] in generation }
            )
        }
    }

    func testImmediateExactAcceptanceUsesResizeMoveResize() {
        let fake = Fake()
        let id: CGWindowID = 7
        let target = CGRect(x: 8, y: 8, width: 492, height: 784)
        fake.frames[id] = CGRect(x: 20, y: 20, width: 800, height: 700)
        let attempt = FrameSizingAttempt(io: fake.io())

        let result = attempt.apply(
            targets: [.init(windowID: id, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            gap: 8,
            generation: 1
        )

        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertEqual(result.actualFrames[id], target)
        XCTAssertEqual(fake.operations, ["timeout:7", "size:7", "timeout:7", "position:7", "timeout:7", "size:7", "timeout:7", "position-read:7", "timeout:7", "size-read:7", "timeout:7", "position-read:7", "timeout:7", "size-read:7"])
    }

    func testDelayedAcceptancePollsWithinDeadline() {
        let fake = Fake()
        let id: CGWindowID = 8
        let target = CGRect(x: 10, y: 10, width: 300, height: 300)
        fake.frames[id] = target
        fake.reads[id] = [(.success, CGRect(x: 10, y: 10, width: 350, height: 300)),
                          (.success, target), (.success, target)]
        fake.sizeReads[id] = [(.success, CGSize(width: 350, height: 300)),
                              (.success, target.size), (.success, target.size)]
        var config = FrameSizingConfiguration()
        config.pollInterval = 0.01
        let result = FrameSizingAttempt(io: fake.io(), configuration: config).apply(
            targets: [.init(windowID: id, frame: target)], usableFrame: CGRect(x: 0, y: 0, width: 800, height: 800),
            gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertEqual(fake.operations.filter { $0 == "position-read:8" }.count, 3)
    }

    func testExplicitWriteErrorIsRejected() {
        let fake = Fake()
        fake.frames[9] = CGRect(x: 0, y: 0, width: 100, height: 100)
        fake.writeErrors = [.cannotComplete]
        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: 9, frame: CGRect(x: 0, y: 0, width: 200, height: 200))],
            usableFrame: CGRect(x: 0, y: 0, width: 800, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .rejected(.writeFailed(9, .cannotComplete)))
    }

    func testFailedReadIsUnknownAndNeverSynthesizesTarget() {
        let fake = Fake()
        fake.frames[10] = CGRect(x: 0, y: 0, width: 100, height: 100)
        fake.reads[10] = [(.cannotComplete, nil)]
        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: 10, frame: CGRect(x: 0, y: 0, width: 200, height: 200))],
            usableFrame: CGRect(x: 0, y: 0, width: 800, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .unknown(.readFailed(10, .cannotComplete)))
        XCTAssertTrue(result.actualFrames.isEmpty)
    }

    func testReadbackTimeoutSetupFailureIsUnknownReadFailure() {
        let fake = Fake()
        let id: CGWindowID = 41
        fake.frames[id] = CGRect(x: 0, y: 0, width: 100, height: 100)
        fake.timeoutErrors = [.success, .success, .success, .cannotComplete]
        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: id,
                            frame: CGRect(x: 0, y: 0, width: 200, height: 200))],
            usableFrame: CGRect(x: 0, y: 0, width: 800, height: 800),
            gap: 8,
            generation: 1
        )
        XCTAssertEqual(result.verdict, .unknown(.readFailed(id, .cannotComplete)))
        XCTAssertEqual(fake.operations, [
            "timeout:41", "size:41",
            "timeout:41", "position:41",
            "timeout:41", "size:41",
            "timeout:41"
        ])
    }

    func testSlowAXCallConsumesRealDeadline() {
        let fake = Fake()
        fake.frames[11] = CGRect(x: 0, y: 0, width: 100, height: 100)
        fake.callAdvance = 0.2
        var config = FrameSizingConfiguration()
        config.deadline = 0.1
        let result = FrameSizingAttempt(io: fake.io(), configuration: config).apply(
            targets: [.init(windowID: 11, frame: CGRect(x: 0, y: 0, width: 200, height: 200))],
            usableFrame: CGRect(x: 0, y: 0, width: 800, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .unknown(.deadlineExceeded))
        XCTAssertEqual(fake.operations, ["timeout:11"])
    }

    func testFullLayoutRejectsPositionContainmentOverlapAndErasedGap() {
        func verdict(_ frames: [CGWindowID: CGRect], targets: [FrameSizingAttempt.Target], gap: CGFloat,
                     tolerance: CGFloat = 1) -> FrameSizingAttempt.Verdict {
            let fake = Fake()
            fake.frames = frames
            for target in targets {
                let frame = frames[target.windowID]!
                fake.reads[target.windowID] = Array(repeating: (.success, frame), count: 12)
                fake.sizeReads[target.windowID] = Array(repeating: (.success, frame.size), count: 12)
            }
            var config = FrameSizingConfiguration()
            config.positionTolerance = tolerance
            config.sizeTolerance = tolerance
            return FrameSizingAttempt(io: fake.io(), configuration: config).apply(targets: targets,
                usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: gap, generation: 1).verdict
        }
        let a = FrameSizingAttempt.Target(windowID: 12, frame: CGRect(x: 0, y: 0, width: 496, height: 800))
        let b = FrameSizingAttempt.Target(windowID: 13, frame: CGRect(x: 504, y: 0, width: 496, height: 800))
        XCTAssertEqual(verdict([12: CGRect(x: 2, y: 0, width: 496, height: 800)], targets: [a], gap: 8),
                       .rejected(.geometryMismatch(12)))
        XCTAssertEqual(verdict([12: CGRect(x: -2, y: 0, width: 496, height: 800)], targets: [a], gap: 8),
                       .rejected(.outsideUsableFrame(12)))
        let overlappingB = FrameSizingAttempt.Target(windowID: 13, frame: CGRect(x: 490, y: 0, width: 510, height: 800))
        XCTAssertEqual(verdict([12: a.frame, 13: overlappingB.frame], targets: [a, overlappingB], gap: 8),
                       .rejected(.overlap(12, 13)))
        XCTAssertEqual(verdict([12: CGRect(x: 0, y: 0, width: 499, height: 800), 13: CGRect(x: 502, y: 0, width: 498, height: 800)], targets: [a, b], gap: 8, tolerance: 3),
                       .rejected(.gapViolation(12, 13)))
    }

    func testRejectedCandidateRestoresOriginalFrames() {
        let fake = Fake()
        let original = CGRect(x: 0, y: 0, width: 500, height: 800)
        let candidate = CGRect(x: 0, y: 0, width: 300, height: 800)
        fake.frames[14] = original
        fake.reads[14] = Array(repeating: (.success, candidate), count: 9) + [(.success, original), (.success, original)]
        fake.sizeReads[14] = Array(repeating: (.success, CGSize(width: 400, height: 800)), count: 9) + [
                              (.success, original.size), (.success, original.size)]
        let attempt = FrameSizingAttempt(io: fake.io())
        let outcome = FrameSizingTransaction(attempt: attempt).apply(
            targets: [.init(windowID: 14, frame: candidate)], originalFrames: [14: original],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(outcome, .rejectedRestored(reason: .geometryMismatch(14), actualFrames: [14: original]))
    }

    func testSupersededAttemptNeverRollsBack() {
        let fake = Fake()
        fake.frames[15] = CGRect(x: 0, y: 0, width: 500, height: 800)
        fake.callAdvance = 0
        var first = true
        let base = fake.io()
        let io = FrameSizingIO(setMessagingTimeout: base.setMessagingTimeout, writeSize: { id, size, timeout in
            let result = base.writeSize(id, size, timeout)
            if first { first = false; fake.generation = 2 }
            return result
        }, writePosition: base.writePosition, readPosition: base.readPosition, readSize: base.readSize,
           now: base.now, sleep: base.sleep, currentGeneration: base.currentGeneration)
        let outcome = FrameSizingTransaction(attempt: FrameSizingAttempt(io: io)).apply(
            targets: [.init(windowID: 15, frame: CGRect(x: 0, y: 0, width: 300, height: 800))],
            originalFrames: [15: CGRect(x: 0, y: 0, width: 500, height: 800)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(outcome, .degraded(candidateReason: .superseded,
                                          restorationReason: nil, actualFrames: [:]))
        XCTAssertEqual(fake.operations, ["timeout:15", "size:15"])
    }

    func testStableMismatchWaitsForMinimumSettleBeforeRejecting() {
        let fake = Fake()
        let id: CGWindowID = 16
        let target = CGRect(x: 0, y: 0, width: 300, height: 800)
        let refused = CGRect(x: 0, y: 0, width: 400, height: 800)
        fake.frames[id] = target
        fake.reads[id] = [(.success, refused), (.success, refused), (.success, target), (.success, target)]
        fake.sizeReads[id] = [(.success, refused.size), (.success, refused.size),
                              (.success, target.size), (.success, target.size)]
        var config = FrameSizingConfiguration()
        config.pollInterval = 0.04
        config.minimumMismatchSettle = 0.12
        let result = FrameSizingAttempt(io: fake.io(), configuration: config).apply(
            targets: [.init(windowID: id, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertEqual(fake.operations.filter { $0 == "position-read:16" }.count, 4)
    }

    func testCumulativeDriftDoesNotCountAsStable() {
        let fake = Fake()
        let id: CGWindowID = 17
        let target = CGRect(x: 0, y: 0, width: 300, height: 800)
        fake.frames[id] = target
        let samples = [0.0, 0.6, 1.2, 1.8].map { CGRect(x: $0, y: 0, width: 300, height: 800) }
        fake.reads[id] = samples.map { (.success, Optional($0)) }
        fake.sizeReads[id] = samples.map { (.success, Optional($0.size)) }
        var config = FrameSizingConfiguration()
        config.maximumAttempts = 4
        config.requiredStableSamples = 3
        config.positionTolerance = 2
        config.stableTolerance = 1
        let result = FrameSizingAttempt(io: fake.io(), configuration: config).apply(
            targets: [.init(windowID: id, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .unknown(.attemptsExhausted))
    }

    func testInvalidAndDuplicateTargetsFailBeforeAXWrites() {
        let fake = Fake()
        let attempt = FrameSizingAttempt(io: fake.io())
        let usable = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let duplicate = attempt.apply(targets: [
            .init(windowID: 18, frame: CGRect(x: 0, y: 0, width: 300, height: 800)),
            .init(windowID: 18, frame: CGRect(x: 308, y: 0, width: 300, height: 800))
        ], usableFrame: usable, gap: 8, generation: 1)
        XCTAssertEqual(duplicate.verdict, .rejected(.duplicateWindowID(18)))
        XCTAssertTrue(fake.operations.isEmpty)

        let invalid = attempt.apply(targets: [
            .init(windowID: 19, frame: CGRect(x: CGFloat.nan, y: 0, width: 300, height: 800))
        ], usableFrame: usable, gap: 8, generation: 1)
        XCTAssertEqual(invalid.verdict, .rejected(.invalidFrame(19)))
        XCTAssertTrue(fake.operations.isEmpty)
    }

    func testPersistentRefusalRejectsOnlyAfterSettleFloor() {
        let fake = Fake()
        let target = CGRect(x: 0, y: 0, width: 300, height: 800)
        let refused = CGRect(x: 0, y: 0, width: 400, height: 800)
        fake.frames[20] = refused
        fake.reads[20] = Array(repeating: (.success, refused), count: 12)
        fake.sizeReads[20] = Array(repeating: (.success, refused.size), count: 12)
        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: 20, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .rejected(.geometryMismatch(20)))
        XCTAssertGreaterThanOrEqual(fake.time, 0.24)
    }

    func testCaptureRequiresCompleteReadableFrames() {
        let fake = Fake()
        fake.frames[21] = CGRect(x: 1, y: 2, width: 300, height: 400)
        let success = FrameSizingAttempt(io: fake.io()).captureFrames(windowIDs: [21], generation: 1)
        XCTAssertEqual(success.verdict, .accepted)
        XCTAssertEqual(success.actualFrames[21], fake.frames[21])

        let missing = FrameSizingAttempt(io: fake.io()).captureFrames(windowIDs: [21, 22], generation: 1)
        XCTAssertEqual(missing.verdict, .unknown(.windowUnavailable(22)))
        XCTAssertEqual(missing.actualFrames, [21: fake.frames[21]!])
    }

    func testUnavailableWindowIsUnknownRatherThanExplicitRejection() {
        let fake = Fake()
        fake.timeoutErrors = [.invalidUIElement]
        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: 23, frame: CGRect(x: 0, y: 0, width: 300, height: 400))],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .unknown(.windowUnavailable(23)))
    }

    func testInvalidActualFrameIsUnknown() {
        let fake = Fake()
        fake.frames[24] = CGRect(x: 0, y: 0, width: 300, height: 400)
        let invalid = CGRect(x: CGFloat.nan, y: 0, width: 300, height: 400)
        fake.reads[24] = [(.success, invalid), (.success, invalid)]
        fake.sizeReads[24] = [(.success, invalid.size), (.success, invalid.size)]
        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: 24, frame: fake.frames[24]!)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .unknown(.invalidFrame(24)))
    }

    func testRestorationFailureRetainsCandidateAndRestoreReasons() {
        let fake = Fake()
        let original = CGRect(x: 0, y: 0, width: 500, height: 800)
        let target = CGRect(x: 0, y: 0, width: 300, height: 800)
        let candidateRefusal = CGRect(x: 0, y: 0, width: 400, height: 800)
        let restoreRefusal = CGRect(x: 0, y: 0, width: 600, height: 800)
        fake.frames[25] = original
        fake.reads[25] = Array(repeating: (.success, candidateRefusal), count: 9)
            + Array(repeating: (.success, restoreRefusal), count: 9)
        fake.sizeReads[25] = Array(repeating: (.success, candidateRefusal.size), count: 9)
            + Array(repeating: (.success, restoreRefusal.size), count: 9)
        let outcome = FrameSizingTransaction(attempt: FrameSizingAttempt(io: fake.io())).apply(
            targets: [.init(windowID: 25, frame: target)], originalFrames: [25: original],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(outcome, .degraded(candidateReason: .geometryMismatch(25),
                                          restorationReason: .geometryMismatch(25),
                                          actualFrames: [25: restoreRefusal]))
    }

    func testPersistentGrowRefusalRejectsSmallerActualFrame() {
        let fake = Fake()
        let target = CGRect(x: 0, y: 0, width: 500, height: 800)
        let refused = CGRect(x: 0, y: 0, width: 400, height: 800)
        fake.frames[26] = target
        fake.reads[26] = Array(repeating: (.success, refused), count: 9)
        fake.sizeReads[26] = Array(repeating: (.success, refused.size), count: 9)
        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: 26, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .rejected(.geometryMismatch(26)))
    }

    func testPositionWriteFailureStopsBeforeSecondSizeWrite() {
        let fake = Fake()
        fake.frames[27] = CGRect(x: 0, y: 0, width: 300, height: 400)
        fake.writeErrors = [.success, .cannotComplete]
        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: 27, frame: CGRect(x: 20, y: 20, width: 300, height: 400))],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .rejected(.writeFailed(27, .cannotComplete)))
        XCTAssertEqual(fake.operations.filter { $0 == "size:27" }.count, 1)
        XCTAssertEqual(fake.operations.filter { $0 == "position:27" }.count, 1)
    }

    func testClampedPositionRejectsWithCorrectSize() {
        let fake = Fake()
        let target = CGRect(x: 100, y: 0, width: 300, height: 400)
        let clamped = CGRect(x: 80, y: 0, width: 300, height: 400)
        fake.frames[28] = target
        fake.reads[28] = Array(repeating: (.success, clamped), count: 9)
        fake.sizeReads[28] = Array(repeating: (.success, target.size), count: 9)
        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: 28, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .rejected(.geometryMismatch(28)))
    }

    func testSizeReadFailureAndIntermittentFailureRemainUnknown() {
        let target = CGRect(x: 0, y: 0, width: 300, height: 400)
        let first = Fake()
        first.frames[29] = target
        first.sizeReads[29] = [(.cannotComplete, nil)]
        let failed = FrameSizingAttempt(io: first.io()).apply(
            targets: [.init(windowID: 29, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(failed.verdict, .unknown(.readFailed(29, .cannotComplete)))
        XCTAssertTrue(failed.actualFrames.isEmpty)

        let second = Fake()
        second.frames[30] = target
        second.reads[30] = [(.success, target), (.cannotComplete, nil)]
        second.sizeReads[30] = [(.success, target.size)]
        let intermittent = FrameSizingAttempt(io: second.io()).apply(
            targets: [.init(windowID: 30, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(intermittent.verdict, .unknown(.readFailed(30, .cannotComplete)))
        XCTAssertEqual(intermittent.actualFrames, [30: target])
    }

    func testNeverSettledStopsAtMonotonicDeadline() {
        let fake = Fake()
        let target = CGRect(x: 0, y: 0, width: 300, height: 400)
        fake.frames[31] = target
        let samples = (0..<12).map { CGRect(x: CGFloat($0 * 3), y: 0, width: 300, height: 400) }
        fake.reads[31] = samples.map { (.success, Optional($0)) }
        fake.sizeReads[31] = samples.map { (.success, Optional($0.size)) }
        var config = FrameSizingConfiguration()
        config.deadline = 0.1
        config.pollInterval = 0.03
        let result = FrameSizingAttempt(io: fake.io(), configuration: config).apply(
            targets: [.init(windowID: 31, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .unknown(.deadlineExceeded))
        XCTAssertGreaterThanOrEqual(fake.time, 0.1)
    }

    func testDefaultToleranceStillRejectsGapErosionAndAcceptsSafeShift() {
        func run(_ actualA: CGRect, _ actualB: CGRect) -> FrameSizingAttempt.Verdict {
            let fake = Fake()
            let a = CGRect(x: 0, y: 0, width: 496, height: 800)
            let b = CGRect(x: 504, y: 0, width: 496, height: 800)
            fake.frames = [32: a, 33: b]
            fake.reads[32] = [(.success, actualA), (.success, actualA)]
            fake.reads[33] = [(.success, actualB), (.success, actualB)]
            fake.sizeReads[32] = [(.success, actualA.size), (.success, actualA.size)]
            fake.sizeReads[33] = [(.success, actualB.size), (.success, actualB.size)]
            return FrameSizingAttempt(io: fake.io()).apply(
                targets: [.init(windowID: 32, frame: a), .init(windowID: 33, frame: b)],
                usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1).verdict
        }
        XCTAssertEqual(run(CGRect(x: 0, y: 0, width: 497, height: 800),
                           CGRect(x: 503, y: 0, width: 497, height: 800)),
                       .rejected(.gapViolation(32, 33)))
        XCTAssertEqual(run(CGRect(x: 1, y: 0, width: 496, height: 800),
                           CGRect(x: 505, y: 0, width: 495, height: 800)), .accepted)
    }

    func testSmallCellQuantizedUndershootIsAcceptedWithObservedFrame() {
        let fake = Fake()
        let id: CGWindowID = 61
        let target = CGRect(x: 20, y: 20, width: 812, height: 1044)
        let quantized = CGRect(x: 20, y: 20, width: 806, height: 1040)
        fake.frames[id] = target
        fake.reads[id] = Array(repeating: (.success, quantized), count: 12)
        fake.sizeReads[id] = Array(repeating: (.success, quantized.size), count: 12)

        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: id, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1200, height: 1200),
            gap: 8,
            generation: 1
        )

        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertEqual(result.actualFrames[id], quantized)
    }

    func testQuantizationAllowanceRejectsOvershootLargeUndershootAndPositionDrift() {
        let target = FrameSizingAttempt.Target(
            windowID: 62,
            frame: CGRect(x: 20, y: 20, width: 812, height: 700)
        )
        let attempt = FrameSizingAttempt(io: Fake().io())
        let usable = CGRect(x: 0, y: 0, width: 1200, height: 900)

        for actual in [
            CGRect(x: 20, y: 20, width: 814, height: 700),
            CGRect(x: 20, y: 20, width: 803, height: 700),
            CGRect(x: 22, y: 20, width: 806, height: 700)
        ] {
            let result = attempt.validateFrames(
                targets: [target], actualFrames: [62: actual],
                usableFrame: usable, gap: 8
            )
            XCTAssertEqual(result.verdict, .rejected(.geometryMismatch(62)), "\(actual)")
        }
    }

    func testQuantizedUndershootDoesNotRelaxContainmentGapOrOverlap() {
        let attempt = FrameSizingAttempt(io: Fake().io())
        let targets = [
            FrameSizingAttempt.Target(windowID: 63, frame: CGRect(x: 0, y: 0, width: 496, height: 800)),
            FrameSizingAttempt.Target(windowID: 64, frame: CGRect(x: 504, y: 0, width: 496, height: 800))
        ]
        let usable = CGRect(x: 0, y: 0, width: 1000, height: 800)

        XCTAssertEqual(attempt.validateFrames(
            targets: targets,
            actualFrames: [
                63: CGRect(x: 0, y: 0, width: 490, height: 800),
                64: CGRect(x: 504, y: 0, width: 490, height: 800)
            ], usableFrame: usable, gap: 8
        ).verdict, .accepted)
        XCTAssertEqual(attempt.validateFrames(
            targets: targets,
            actualFrames: [63: targets[0].frame, 64: CGRect(x: 503, y: 0, width: 490, height: 800)],
            usableFrame: usable, gap: 8
        ).verdict, .rejected(.gapViolation(63, 64)))
        let touchingTargets = [
            FrameSizingAttempt.Target(windowID: 63, frame: CGRect(x: 0, y: 0, width: 500, height: 800)),
            FrameSizingAttempt.Target(windowID: 64, frame: CGRect(x: 500, y: 0, width: 500, height: 800))
        ]
        XCTAssertEqual(attempt.validateFrames(
            targets: touchingTargets,
            actualFrames: [
                63: CGRect(x: 0, y: 0, width: 501, height: 800),
                64: CGRect(x: 499, y: 0, width: 501, height: 800)
            ], usableFrame: usable, gap: 0
        ).verdict, .rejected(.overlap(63, 64)))
        XCTAssertEqual(attempt.validateFrames(
            targets: [targets[0]],
            actualFrames: [63: CGRect(x: -1, y: 0, width: 490, height: 800)],
            usableFrame: usable, gap: 8
        ).verdict, .rejected(.outsideUsableFrame(63)))
    }

    func testRestorationRequiresExactSizeDespiteCandidateQuantizationAllowance() {
        let fake = Fake()
        let id: CGWindowID = 65
        let original = CGRect(x: 20, y: 20, width: 812, height: 700)
        let undershotRestore = CGRect(x: 20, y: 20, width: 806, height: 700)
        fake.frames[id] = original
        fake.writeErrors = [.cannotComplete]
        fake.reads[id] = Array(repeating: (.success, undershotRestore), count: 12)
        fake.sizeReads[id] = Array(repeating: (.success, undershotRestore.size), count: 12)

        let outcome = FrameSizingTransaction(attempt: FrameSizingAttempt(io: fake.io())).apply(
            targets: [.init(windowID: id, frame: CGRect(x: 20, y: 20, width: 600, height: 700))],
            originalFrames: [id: original],
            usableFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            gap: 8,
            generation: 1
        )

        XCTAssertEqual(outcome, .degraded(
            candidateReason: .writeFailed(id, .cannotComplete),
            restorationReason: .geometryMismatch(id),
            actualFrames: [id: undershotRestore]
        ))
    }

    func testCaptureStopsWhenSizeTimeoutSetupCrossesDeadline() {
        let fake = Fake()
        fake.frames[34] = CGRect(x: 0, y: 0, width: 300, height: 400)
        fake.timeoutAdvances = [0, 0.2]
        var config = FrameSizingConfiguration()
        config.deadline = 0.1
        let result = FrameSizingAttempt(io: fake.io(), configuration: config)
            .captureFrames(windowIDs: [34], generation: 1)
        XCTAssertEqual(result.verdict, .unknown(.deadlineExceeded))
        XCTAssertFalse(fake.operations.contains("size-read:34"))
    }

    func testCaptureRejectsDuplicateAndInvalidFrames() {
        let fake = Fake()
        fake.frames[35] = CGRect(x: 0, y: 0, width: 300, height: 400)
        let duplicate = FrameSizingAttempt(io: fake.io()).captureFrames(windowIDs: [35, 35], generation: 1)
        XCTAssertEqual(duplicate.verdict, .unknown(.duplicateWindowID(35)))

        let invalid = CGRect(x: CGFloat.nan, y: 0, width: 300, height: 400)
        fake.reads[35] = [(.success, invalid)]
        fake.sizeReads[35] = [(.success, invalid.size)]
        let invalidResult = FrameSizingAttempt(io: fake.io()).captureFrames(windowIDs: [35], generation: 1)
        XCTAssertEqual(invalidResult.verdict, .unknown(.invalidFrame(35)))
    }

    func testEmptyOperationsStillHonorSupersession() {
        let fake = Fake()
        fake.generation = 2
        let attempt = FrameSizingAttempt(io: fake.io())
        XCTAssertEqual(attempt.apply(targets: [], usableFrame: .zero, gap: 8, generation: 1).verdict,
                       .unknown(.superseded))
        XCTAssertEqual(attempt.captureFrames(windowIDs: [], generation: 1).verdict,
                       .unknown(.superseded))
    }

    func testNegativeRawTargetSizeRejectsBeforeWrites() {
        let fake = Fake()
        let raw = CGRect(origin: .zero, size: CGSize(width: -300, height: 400))
        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: 36, frame: raw)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .rejected(.invalidFrame(36)))
        XCTAssertTrue(fake.operations.isEmpty)
    }

    func testFrameWriteUsesOneBracketAroundResizeMoveResize() {
        let fake = Fake()
        let id: CGWindowID = 39
        let target = CGRect(x: 8, y: 8, width: 492, height: 784)
        fake.frames[id] = target
        let base = fake.io()
        let token = AXFrameWriteBatch.Token.noop(windowID: id)
        let io = FrameSizingIO(
            setMessagingTimeout: base.setMessagingTimeout,
            writeSize: base.writeSize,
            writePosition: base.writePosition,
            readPosition: base.readPosition,
            readSize: base.readSize,
            now: base.now,
            sleep: base.sleep,
            currentGeneration: base.currentGeneration,
            beginFrameWrite: { [unowned fake] windowID, _, _ in
                fake.operations.append("begin:\(windowID)")
                return .ready(token)
            },
            endFrameWrite: { [unowned fake] _, _, _ in
                fake.operations.append("end")
                return .restored
            }
        )

        XCTAssertEqual(FrameSizingAttempt(io: io).apply(
            targets: [.init(windowID: id, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            gap: 8, generation: 1).verdict, .accepted)
        let writes = fake.operations.filter { operation in
            operation == "begin:39" || operation == "size:39"
                || operation == "position:39" || operation == "end"
        }
        XCTAssertEqual(writes, ["begin:39", "size:39", "position:39", "size:39", "end"])
    }

    func testFrameWriteFailureStillEndsBracket() {
        for failingWrite in 0..<3 {
            let fake = Fake()
            let id = CGWindowID(40 + failingWrite)
            fake.frames[id] = CGRect(x: 0, y: 0, width: 500, height: 500)
            fake.writeErrors = (0..<3).map { $0 == failingWrite ? .cannotComplete : .success }
            let base = fake.io()
            let io = FrameSizingIO(
                setMessagingTimeout: base.setMessagingTimeout,
                writeSize: base.writeSize,
                writePosition: base.writePosition,
                readPosition: base.readPosition,
                readSize: base.readSize,
                now: base.now,
                sleep: base.sleep,
                currentGeneration: base.currentGeneration,
                beginFrameWrite: { _, _, _ in .ready(.noop(windowID: id)) },
                endFrameWrite: { [unowned fake] _, _, _ in
                    fake.operations.append("end")
                    return .restored
                }
            )
            _ = FrameSizingAttempt(io: io).apply(
                targets: [.init(windowID: id, frame: CGRect(x: 0, y: 0, width: 300, height: 300))],
                usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
            XCTAssertEqual(fake.operations.filter { $0 == "end" }.count, 1,
                           "write index \(failingWrite) did not clean up")
        }
    }

    func testInterruptionDuringBeginCleansUpWithoutGeometryWrites() {
        let fake = Fake()
        let id: CGWindowID = 43
        fake.frames[id] = CGRect(x: 0, y: 0, width: 500, height: 500)
        let base = fake.io()
        let token = AXFrameWriteBatch.Token.noop(windowID: id)
        let io = FrameSizingIO(
            setMessagingTimeout: base.setMessagingTimeout,
            writeSize: base.writeSize,
            writePosition: base.writePosition,
            readPosition: base.readPosition,
            readSize: base.readSize,
            now: base.now,
            sleep: base.sleep,
            currentGeneration: base.currentGeneration,
            beginFrameWrite: { _, _, _ in .interruptedAfterBegin(token, .superseded) },
            endFrameWrite: { [unowned fake] _, _, _ in
                fake.operations.append("end")
                return .restored
            }
        )

        let result = FrameSizingAttempt(io: io).apply(
            targets: [.init(windowID: id, frame: CGRect(x: 0, y: 0, width: 300, height: 300))],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .unknown(.superseded))
        XCTAssertEqual(fake.operations, ["end"])
    }

    func testDiagonalWindowsCannotErodeBothAxisGaps() {
        let fake = Fake()
        let targetA = CGRect(x: 0, y: 0, width: 496, height: 396)
        let targetB = CGRect(x: 504, y: 404, width: 496, height: 396)
        let actualA = CGRect(x: 0, y: 0, width: 497, height: 397)
        let actualB = CGRect(x: 503, y: 403, width: 497, height: 397)
        fake.frames = [37: targetA, 38: targetB]
        fake.reads[37] = [(.success, actualA), (.success, actualA)]
        fake.reads[38] = [(.success, actualB), (.success, actualB)]
        fake.sizeReads[37] = [(.success, actualA.size), (.success, actualA.size)]
        fake.sizeReads[38] = [(.success, actualB.size), (.success, actualB.size)]
        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: 37, frame: targetA), .init(windowID: 38, frame: targetB)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .rejected(.gapViolation(37, 38)))
    }

    func testDefaultStabilityDoesNotAcceptContinuousSubpointMotion() {
        let fake = Fake()
        let target = CGRect(x: 0, y: 0, width: 300, height: 400)
        fake.frames[50] = target
        let samples = (0..<12).map { CGRect(x: CGFloat($0) * 0.5, y: 0, width: 300, height: 400) }
        fake.reads[50] = samples.map { (.success, Optional($0)) }
        fake.sizeReads[50] = samples.map { (.success, Optional($0.size)) }
        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: 50, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .unknown(.attemptsExhausted))
    }

    func testSlowGeometryWriteAndReadConsumeDeadline() {
        let target = CGRect(x: 0, y: 0, width: 300, height: 400)
        let writeFake = Fake()
        writeFake.frames[51] = target
        writeFake.writeAdvances = [0.2]
        var config = FrameSizingConfiguration()
        config.deadline = 0.1
        let writeResult = FrameSizingAttempt(io: writeFake.io(), configuration: config).apply(
            targets: [.init(windowID: 51, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(writeResult.verdict, .unknown(.deadlineExceeded))
        XCTAssertFalse(writeFake.operations.contains("position:51"))

        let readFake = Fake()
        readFake.frames[52] = target
        readFake.sizeReadAdvances = [0.2]
        let readResult = FrameSizingAttempt(io: readFake.io(), configuration: config).apply(
            targets: [.init(windowID: 52, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(readResult.verdict, .unknown(.deadlineExceeded))
        XCTAssertEqual(readFake.operations.filter { $0 == "size-read:52" }.count, 1)
    }

    func testUnreadableRestorationRetainsBothReasons() {
        let fake = Fake()
        let original = CGRect(x: 0, y: 0, width: 500, height: 400)
        fake.frames[53] = original
        fake.writeErrors = [.cannotComplete]
        fake.reads[53] = [(.cannotComplete, nil)]
        let outcome = FrameSizingTransaction(attempt: FrameSizingAttempt(io: fake.io())).apply(
            targets: [.init(windowID: 53, frame: CGRect(x: 0, y: 0, width: 300, height: 400))],
            originalFrames: [53: original],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(outcome, .degraded(candidateReason: .writeFailed(53, .cannotComplete),
                                          restorationReason: .readFailed(53, .cannotComplete),
                                          actualFrames: [:]))
    }

    func testCleanupFailurePreservesWindowAndPrimaryReason() {
        func makeIO(_ fake: Fake, endError: AXError,
                    write: @escaping (CGWindowID, CGSize, TimeInterval) -> AXError) -> FrameSizingIO {
            let base = fake.io()
            return FrameSizingIO(
                setMessagingTimeout: base.setMessagingTimeout, writeSize: write,
                writePosition: base.writePosition, readPosition: base.readPosition,
                readSize: base.readSize, now: base.now, sleep: base.sleep,
                currentGeneration: base.currentGeneration,
                beginFrameWrite: { id, _, _ in .ready(.noop(windowID: id)) },
                endFrameWrite: { _, _, _ in .failed(endError) })
        }
        let target = CGRect(x: 0, y: 0, width: 300, height: 400)

        let successFake = Fake()
        successFake.frames[54] = target
        let successBase = successFake.io()
        let success = FrameSizingAttempt(io: makeIO(successFake, endError: .cannotComplete,
                                                     write: successBase.writeSize)).apply(
            targets: [.init(windowID: 54, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(success.verdict,
                       .unknown(.cleanupFailed(54, primary: nil, error: .cannotComplete)))

        let failureFake = Fake()
        failureFake.frames[55] = target
        let failureBase = failureFake.io()
        var failed = false
        let failure = FrameSizingAttempt(io: makeIO(failureFake, endError: .cannotComplete) { id, size, timeout in
            if !failed { failed = true; return .illegalArgument }
            return failureBase.writeSize(id, size, timeout)
        }).apply(targets: [.init(windowID: 55, frame: target)],
                 usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(failure.verdict,
                       .unknown(.cleanupFailed(55, primary: .writeFailed(55, .illegalArgument),
                                               error: .cannotComplete)))

        let supersededFake = Fake()
        supersededFake.frames[56] = target
        let supersededBase = supersededFake.io()
        let superseded = FrameSizingAttempt(io: makeIO(supersededFake, endError: .cannotComplete) { id, size, timeout in
            let result = supersededBase.writeSize(id, size, timeout)
            supersededFake.generation = 2
            return result
        }).apply(targets: [.init(windowID: 56, frame: target)],
                 usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(superseded.verdict,
                       .unknown(.cleanupFailed(56, primary: .superseded, error: .cannotComplete)))
    }

    func testCleanupWrappedSupersessionNeverRollsBack() {
        let fake = Fake()
        let id: CGWindowID = 57
        let original = CGRect(x: 0, y: 0, width: 500, height: 400)
        fake.frames[id] = original
        let base = fake.io()
        let io = FrameSizingIO(
            setMessagingTimeout: base.setMessagingTimeout,
            writeSize: { windowID, size, timeout in
                let result = base.writeSize(windowID, size, timeout)
                fake.generation = 2
                return result
            },
            writePosition: base.writePosition, readPosition: base.readPosition,
            readSize: base.readSize, now: base.now, sleep: base.sleep,
            currentGeneration: base.currentGeneration,
            beginFrameWrite: { windowID, _, _ in .ready(.noop(windowID: windowID)) },
            endFrameWrite: { _, _, _ in .failed(.cannotComplete) }
        )
        let outcome = FrameSizingTransaction(attempt: FrameSizingAttempt(io: io)).apply(
            targets: [.init(windowID: id, frame: CGRect(x: 0, y: 0, width: 300, height: 400))],
            originalFrames: [id: original],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(outcome, .degraded(
            candidateReason: .cleanupFailed(id, primary: .superseded, error: .cannotComplete),
            restorationReason: nil, actualFrames: [:]))
        XCTAssertEqual(fake.operations.filter { $0 == "size:57" }.count, 1)
        XCTAssertFalse(fake.operations.contains("position:57"))
    }

    func testSupersessionDuringRestorationStopsRemainingWrites() {
        let fake = Fake()
        let first: CGWindowID = 58
        let second: CGWindowID = 59
        let originalA = CGRect(x: 0, y: 0, width: 496, height: 400)
        let originalB = CGRect(x: 504, y: 0, width: 496, height: 400)
        fake.frames = [first: originalA, second: originalB]
        let base = fake.io()
        var sizeCalls = 0
        let io = FrameSizingIO(
            setMessagingTimeout: base.setMessagingTimeout,
            writeSize: { id, size, timeout in
                sizeCalls += 1
                if sizeCalls == 1 { return .cannotComplete }
                let result = base.writeSize(id, size, timeout)
                fake.generation = 2
                return result
            },
            writePosition: base.writePosition, readPosition: base.readPosition,
            readSize: base.readSize, now: base.now, sleep: base.sleep,
            currentGeneration: base.currentGeneration
        )
        let transaction = FrameSizingTransaction(attempt: FrameSizingAttempt(io: io))
        let outcome = transaction.apply(
            targets: [.init(windowID: first, frame: originalA), .init(windowID: second, frame: originalB)],
            originalFrames: [first: originalA, second: originalB],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(outcome, .degraded(candidateReason: .writeFailed(first, .cannotComplete),
                                          restorationReason: .superseded, actualFrames: [:]))
        XCTAssertEqual(sizeCalls, 2)
        XCTAssertFalse(fake.operations.contains("position:58"))
        XCTAssertFalse(fake.operations.contains("size:59"))
    }

    func testNeverSettledRestorationIsDegraded() {
        let fake = Fake()
        let id: CGWindowID = 60
        let original = CGRect(x: 0, y: 0, width: 500, height: 400)
        fake.frames[id] = original
        fake.writeErrors = [.cannotComplete]
        let unsettled = (0..<12).map { CGRect(x: CGFloat($0 * 3), y: 0, width: 500, height: 400) }
        fake.reads[id] = unsettled.map { (.success, Optional($0)) }
        fake.sizeReads[id] = unsettled.map { (.success, Optional($0.size)) }
        let outcome = FrameSizingTransaction(attempt: FrameSizingAttempt(io: fake.io())).apply(
            targets: [.init(windowID: id, frame: CGRect(x: 0, y: 0, width: 300, height: 400))],
            originalFrames: [id: original],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(outcome, .degraded(candidateReason: .writeFailed(id, .cannotComplete),
                                          restorationReason: .attemptsExhausted,
                                          actualFrames: [id: unsettled.last!]))
    }
}
