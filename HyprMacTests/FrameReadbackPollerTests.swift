import XCTest
@testable import HyprMac

final class FrameReadbackPollerTests: XCTestCase {
    func testEmptyLayoutStillHonorsSupersession() {
        let io = FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { _, _, _ in .success },
            writePosition: { _, _, _ in .success },
            readPosition: { _, _ in (.success, .zero) },
            readSize: { _, _ in (.success, CGSize(width: 100, height: 100)) },
            now: { 0 }, sleep: { _ in }, currentGeneration: { 2 }
        )
        let result = FrameReadbackPoller(generation: { 2 }, ioFactory: { _, _ in io })
            .applyLayout([], usableFrame: .zero, gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .unknown(.superseded))
    }

    func testDuplicateCaptureInputsFailSafelyBeforeDictionaryConstruction() {
        let window = makeWindow(id: 38)
        let io = FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { _, _, _ in .success },
            writePosition: { _, _, _ in .success },
            readPosition: { _, _ in (.success, .zero) },
            readSize: { _, _ in (.success, CGSize(width: 100, height: 100)) },
            now: { 0 }, sleep: { _ in }, currentGeneration: { 1 }
        )
        let result = FrameReadbackPoller(generation: { 1 }, ioFactory: { _, _ in io })
            .captureFrames([window, window], generation: 1)
        XCTAssertEqual(result.verdict, .unknown(.duplicateWindowID(38)))
    }

    func testDuplicateInputsRejectWithoutDictionaryTrapOrAXCalls() {
        let window = makeWindow(id: 39)
        var called = false
        let io = FrameSizingIO(
            setMessagingTimeout: { _, _ in called = true; return .success },
            writeSize: { _, _, _ in called = true; return .success },
            writePosition: { _, _, _ in called = true; return .success },
            readPosition: { _, _ in called = true; return (.success, .zero) },
            readSize: { _, _ in called = true; return (.success, CGSize(width: 100, height: 100)) },
            now: { 0 }, sleep: { _ in }, currentGeneration: { 1 }
        )
        let target = CGRect(x: 0, y: 0, width: 300, height: 400)
        let result = FrameReadbackPoller(generation: { 1 }, ioFactory: { _, _ in io })
            .applyLayout([(window, target), (window, target)],
                         usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                         gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .rejected(.duplicateWindowID(39)))
        XCTAssertFalse(called)
    }

    func testUnknownReadbackDoesNotCacheOrProduceMinimumEvidence() {
        let window = makeWindow(id: 40)
        let original = CGRect(x: 20, y: 20, width: 600, height: 500)
        let target = CGRect(x: 0, y: 0, width: 300, height: 400)
        window.cachedFrame = original
        var reads = 0
        var time: TimeInterval = 0
        let io = FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { _, _, _ in .success },
            writePosition: { _, _, _ in .success },
            readPosition: { _, _ in
                reads += 1
                return reads == 1 ? (.success, CGPoint.zero) : (.cannotComplete, nil)
            },
            readSize: { _, _ in (.success, CGSize(width: 450, height: 400)) },
            now: { time }, sleep: { time += $0 }, currentGeneration: { 1 }
        )
        let poller = FrameReadbackPoller(generation: { 1 }, ioFactory: { _, _ in io })
        let result = poller.applyLayout([(window, target)],
                                        usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                        gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .unknown(.readFailed(40, .cannotComplete)))
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertTrue(result.observations.isEmpty)
        XCTAssertTrue(result.accepted.isEmpty)
        XCTAssertNil(window.cachedFrame)
    }

    func testFinalPassReturnsVerifiedRejection() {
        let window = makeWindow(id: 41)
        let target = CGRect(x: 0, y: 0, width: 300, height: 400)
        var time: TimeInterval = 0
        let io = FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { _, _, _ in .success },
            writePosition: { _, _, _ in .success },
            readPosition: { _, _ in (.success, CGPoint.zero) },
            readSize: { _, _ in (.success, CGSize(width: 450, height: 400)) },
            now: { time }, sleep: { time += $0 }, currentGeneration: { 1 }
        )
        let result = FrameReadbackPoller(generation: { 1 }, ioFactory: { _, _ in io })
            .applyFinal([(window, target)],
                        usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                        gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .rejected(.geometryMismatch(41)))
        XCTAssertEqual(result.conflicts.count, 1)
    }

    func testCellRoundedOvershootAcceptsAndTeachesNoMinimum() {
        let window = makeWindow(id: 43)
        let target = CGRect(x: 20, y: 20, width: 3424, height: 1301)
        let rounded = CGRect(x: 20, y: 20, width: 3425, height: 1309)
        var time: TimeInterval = 0
        let io = FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { _, _, _ in .success },
            writePosition: { _, _, _ in .success },
            readPosition: { _, _ in (.success, rounded.origin) },
            readSize: { _, _ in (.success, rounded.size) },
            now: { time }, sleep: { time += $0 }, currentGeneration: { 1 }
        )
        let result = FrameReadbackPoller(generation: { 1 }, ioFactory: { _, _ in io })
            .applyLayout([(window, target)],
                         usableFrame: CGRect(x: 0, y: 0, width: 3600, height: 1400),
                         gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertTrue(result.observations.isEmpty)
        XCTAssertEqual(result.accepted.count, 1)
        XCTAssertNil(window.observedMinSize)
    }

    func testRejectedLayoutBlamesTheOversizedWindowNotTheRoundedOne() {
        let rounded = makeWindow(id: 44)
        let oversized = makeWindow(id: 45)
        let roundedTarget = CGRect(x: 0, y: 0, width: 500, height: 800)
        let oversizedTarget = CGRect(x: 508, y: 0, width: 492, height: 800)
        let actual: [CGWindowID: CGRect] = [
            44: CGRect(x: 0, y: 0, width: 508, height: 800),
            45: CGRect(x: 508, y: 0, width: 600, height: 800)
        ]
        var time: TimeInterval = 0
        let io = FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { _, _, _ in .success },
            writePosition: { _, _, _ in .success },
            readPosition: { id, _ in (.success, actual[id]?.origin) },
            readSize: { id, _ in (.success, actual[id]?.size) },
            now: { time }, sleep: { time += $0 }, currentGeneration: { 1 }
        )
        let result = FrameReadbackPoller(generation: { 1 }, ioFactory: { _, _ in io })
            .applyLayout([(rounded, roundedTarget), (oversized, oversizedTarget)],
                         usableFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                         gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .rejected(.geometryMismatch(45)))
        XCTAssertEqual(result.conflicts.map { $0.window.windowID }, [45])
        XCTAssertEqual(result.observations.map { $0.window.windowID }, [45])
    }

    func testSupersededReadbackPreservesNewerCachedFrame() {
        let window = makeWindow(id: 42)
        let target = CGRect(x: 0, y: 0, width: 300, height: 400)
        let newer = CGRect(x: 500, y: 0, width: 500, height: 800)
        window.cachedFrame = target
        var generation: UInt64 = 1
        let io = FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { _, _, _ in .success },
            writePosition: { _, _, _ in .success },
            readPosition: { _, _ in
                window.cachedFrame = newer
                generation = 2
                return (.success, target.origin)
            },
            readSize: { _, _ in (.success, target.size) },
            now: { 0 }, sleep: { _ in }, currentGeneration: { generation }
        )
        let result = FrameReadbackPoller(generation: { generation }, ioFactory: { _, _ in io })
            .applyLayout([(window, target)],
                         usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                         gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .unknown(.superseded))
        XCTAssertEqual(window.cachedFrame, newer)
    }
}
