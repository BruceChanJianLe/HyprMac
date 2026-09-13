import XCTest
@testable import HyprMac

final class AXFrameWriteBatchTests: XCTestCase {
    private final class FakeRaw {
        var enhancedValue: AnyObject? = kCFBooleanTrue
        var copyError: AXError = .success
        var timeoutError: AXError = .success
        var timeoutErrors: [AXError] = []
        var disableError: AXError = .success
        var restoreError: AXError = .success
        var operations: [String] = []
        let application = AXFrameWriteBatch.Application()
        var sawDifferentApplication = false

        func operationsAdapter() -> AXFrameWriteBatch.RawOperations {
            AXFrameWriteBatch.RawOperations(
                makeApplication: { [unowned self] _ in application },
                setApplicationTimeout: { [unowned self] app, _ in
                    sawDifferentApplication = sawDifferentApplication || app !== application
                    operations.append("app-timeout")
                    if !timeoutErrors.isEmpty { return timeoutErrors.removeFirst() }
                    return timeoutError
                },
                copyEnhancedUI: { [unowned self] app in
                    sawDifferentApplication = sawDifferentApplication || app !== application
                    operations.append("enhanced-read")
                    return (copyError, enhancedValue)
                },
                setEnhancedUI: { [unowned self] app, enabled in
                    sawDifferentApplication = sawDifferentApplication || app !== application
                    operations.append("enhanced-\(enabled ? "on" : "off")")
                    return enabled ? restoreError : disableError
                }
            )
        }
    }

    func testSingleEnhancedUIBracketSurroundsResizeMoveResize() throws {
        let fake = FakeRaw()
        let batch = AXFrameWriteBatch(raw: fake.operationsAdapter())

        let token: AXFrameWriteBatch.Token
        switch batch.begin(ownerPID: 42, timeout: 0.1, checkpoint: { nil }) {
        case let .ready(value): token = value
        case let .failed(error): return XCTFail("begin failed: \(error)")
        case let .failedAfterCleanup(primary, cleanup):
            return XCTFail("begin failed: \(primary), cleanup: \(cleanup)")
        case let .interrupted(reason): return XCTFail("begin interrupted: \(reason)")
        case let .interruptedAfterBegin(_, reason): return XCTFail("begin interrupted: \(reason)")
        }
        fake.operations.append("size")
        fake.operations.append("position")
        fake.operations.append("size")
        XCTAssertEqual(batch.end(token, timeout: 0.1, checkpoint: { nil }), .restored)

        XCTAssertEqual(fake.operations, [
            "app-timeout", "enhanced-read", "app-timeout", "enhanced-off",
            "size", "position", "size", "app-timeout", "enhanced-on"
        ])
        XCTAssertFalse(fake.sawDifferentApplication)
    }

    func testEnhancedUIReadFailureStopsBeforeFrameWrites() {
        let fake = FakeRaw()
        fake.copyError = .cannotComplete
        let batch = AXFrameWriteBatch(raw: fake.operationsAdapter())

        XCTAssertEqual(batch.begin(ownerPID: 43, timeout: 0.1, checkpoint: { nil }),
                       .failed(.cannotComplete))
        XCTAssertEqual(fake.operations, ["app-timeout", "enhanced-read"])
    }

    func testCleanupFailureIsReturnedAfterPrimaryOperationAborts() throws {
        let fake = FakeRaw()
        fake.restoreError = .cannotComplete
        let batch = AXFrameWriteBatch(raw: fake.operationsAdapter())
        let token: AXFrameWriteBatch.Token
        switch batch.begin(ownerPID: 44, timeout: 0.1, checkpoint: { nil }) {
        case let .ready(value): token = value
        case let .failed(error): return XCTFail("begin failed: \(error)")
        case let .failedAfterCleanup(primary, cleanup):
            return XCTFail("begin failed: \(primary), cleanup: \(cleanup)")
        case let .interrupted(reason): return XCTFail("begin interrupted: \(reason)")
        case let .interruptedAfterBegin(_, reason): return XCTFail("begin interrupted: \(reason)")
        }

        fake.operations.append("position-failed")
        XCTAssertEqual(batch.end(token, timeout: 0.1, checkpoint: { .superseded }),
                       .failed(.cannotComplete))
        XCTAssertEqual(fake.operations, [
            "app-timeout", "enhanced-read", "app-timeout", "enhanced-off",
            "position-failed", "app-timeout", "enhanced-on"
        ])
    }

    func testTypedPointAndSizeDecodingRejectsWrongTypesAndNonfiniteValues() throws {
        var point = CGPoint(x: 12, y: 34)
        let pointValue = try XCTUnwrap(AXValueCreate(.cgPoint, &point))
        XCTAssertEqual(AXFrameValueDecoder.point(error: .success, value: pointValue).1, point)
        XCTAssertNil(AXFrameValueDecoder.size(error: .success, value: pointValue).1)

        var size = CGSize(width: 640, height: 480)
        let sizeValue = try XCTUnwrap(AXValueCreate(.cgSize, &size))
        XCTAssertEqual(AXFrameValueDecoder.size(error: .success, value: sizeValue).1, size)

        var invalidSize = CGSize(width: CGFloat.infinity, height: 20)
        let invalidSizeValue = try XCTUnwrap(AXValueCreate(.cgSize, &invalidSize))
        XCTAssertNil(AXFrameValueDecoder.size(error: .success, value: invalidSizeValue).1)
        XCTAssertNil(AXFrameValueDecoder.point(error: .success, value: "wrong" as NSString).1)
    }

    func testUnsupportedEnhancedUIAttributeNeedsNoToggleOrCleanupWrite() {
        let fake = FakeRaw()
        fake.copyError = .attributeUnsupported
        let batch = AXFrameWriteBatch(raw: fake.operationsAdapter())
        let token: AXFrameWriteBatch.Token
        switch batch.begin(ownerPID: 45, timeout: 0.1, checkpoint: { nil }) {
        case let .ready(value): token = value
        case let .failed(error): return XCTFail("begin failed: \(error)")
        case let .failedAfterCleanup(primary, cleanup):
            return XCTFail("begin failed: \(primary), cleanup: \(cleanup)")
        case let .interrupted(reason): return XCTFail("begin interrupted: \(reason)")
        case let .interruptedAfterBegin(_, reason): return XCTFail("begin interrupted: \(reason)")
        }

        XCTAssertEqual(batch.end(token, timeout: 0.1, checkpoint: { nil }), .restored)
        XCTAssertEqual(fake.operations, ["app-timeout", "enhanced-read"])
    }

    func testApplicationTimeoutFailureStopsBeforeEnhancedUIRead() {
        let fake = FakeRaw()
        fake.timeoutError = .cannotComplete
        let batch = AXFrameWriteBatch(raw: fake.operationsAdapter())

        XCTAssertEqual(batch.begin(ownerPID: 46, timeout: 0.1, checkpoint: { nil }),
                       .failed(.cannotComplete))
        XCTAssertEqual(fake.operations, ["app-timeout"])
    }

    func testInterruptionBeforeAndAfterRawCallStopsBegin() {
        let fake = FakeRaw()
        let batch = AXFrameWriteBatch(raw: fake.operationsAdapter())
        XCTAssertEqual(batch.begin(ownerPID: 47, timeout: 0.1,
                                   checkpoint: { .superseded }),
                       .interrupted(.superseded))
        XCTAssertTrue(fake.operations.isEmpty)

        var checkpoints: [FrameSizingFailure?] = [nil, .deadlineExceeded]
        XCTAssertEqual(batch.begin(ownerPID: 48, timeout: 0.1,
                                   checkpoint: { checkpoints.removeFirst() }),
                       .interrupted(.deadlineExceeded))
        XCTAssertEqual(fake.operations, ["app-timeout"])
    }

    func testInterruptionDuringDisableReturnsCleanupTokenAndRestoresSameApplication() {
        let fake = FakeRaw()
        let batch = AXFrameWriteBatch(raw: fake.operationsAdapter())
        var count = 0
        let result = batch.begin(ownerPID: 49, timeout: 0.1, checkpoint: {
            count += 1
            return count == 5 ? .superseded : nil
        })
        let token: AXFrameWriteBatch.Token
        switch result {
        case let .interruptedAfterBegin(value, reason):
            XCTAssertEqual(reason, .superseded)
            token = value
        default:
            return XCTFail("expected cleanup token, got \(result)")
        }

        XCTAssertEqual(batch.end(token, timeout: 0.1, checkpoint: { .superseded }), .restored)
        XCTAssertEqual(fake.operations, [
            "app-timeout", "enhanced-read", "app-timeout", "enhanced-off",
            "app-timeout", "enhanced-on"
        ])
        XCTAssertFalse(fake.sawDifferentApplication)
    }

    func testFailedDisableStillAttemptsCleanupBecauseWriteMayHaveTakenEffect() {
        let fake = FakeRaw()
        fake.disableError = .cannotComplete
        let batch = AXFrameWriteBatch(raw: fake.operationsAdapter())

        XCTAssertEqual(batch.begin(ownerPID: 50, timeout: 0.1, checkpoint: { nil }),
                       .failed(.cannotComplete))
        XCTAssertEqual(fake.operations, [
            "app-timeout", "enhanced-read", "app-timeout", "enhanced-off",
            "app-timeout", "enhanced-on"
        ])
    }

    func testCleanupAttemptsRestoreAfterTimeoutResetFailure() {
        let fake = FakeRaw()
        let batch = AXFrameWriteBatch(raw: fake.operationsAdapter())
        let token: AXFrameWriteBatch.Token
        switch batch.begin(ownerPID: 51, timeout: 0.1, checkpoint: { nil }) {
        case let .ready(value): token = value
        default: return XCTFail("begin failed")
        }
        fake.timeoutErrors = [.cannotComplete]
        fake.restoreError = .notImplemented

        let result = batch.end(token, timeout: 0.1, checkpoint: { nil })
        XCTAssertEqual(fake.operations.suffix(2), ["app-timeout", "enhanced-on"])
        XCTAssertEqual(result, .failedTimeoutAndRestore(timeout: .cannotComplete,
                                                        restore: .notImplemented))
    }

    func testDisableAndCleanupFailuresPreserveBothDiagnostics() {
        let fake = FakeRaw()
        fake.disableError = .cannotComplete
        fake.restoreError = .notImplemented
        let batch = AXFrameWriteBatch(raw: fake.operationsAdapter())

        let result = batch.begin(ownerPID: 52, timeout: 0.1, checkpoint: { nil })
        XCTAssertEqual(fake.operations.suffix(2), ["app-timeout", "enhanced-on"])
        XCTAssertEqual(result, .failedAfterCleanup(primary: .cannotComplete,
                                                    cleanup: .failed(.notImplemented)))
    }

    func testNoopTokenNeedsNoRawCallsToEnd() {
        let fake = FakeRaw()
        let batch = AXFrameWriteBatch(raw: fake.operationsAdapter())

        // the default FrameSizingIO and the probe's plain mode both end a
        // noop token — that must not touch the app element
        XCTAssertEqual(batch.end(.noop(windowID: 91), timeout: 0.1, checkpoint: { nil }),
                       .restored)
        XCTAssertTrue(fake.operations.isEmpty)
    }
}
