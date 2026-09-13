import Cocoa
import XCTest
@testable import HyprMac

#if DEBUG

final class ProbeFrameArgumentsTests: XCTestCase {
    func testAbsentFlagIsNotAProbeLaunch() {
        XCTAssertNil(ProbeFrameArguments.parse(["/path/HyprMac Debug", "--check-accessibility"]))
    }

    func testPositionalsAndDefaults() throws {
        let parsed = try parse(["--probe-frame", "24889", "-1072", "-88", "1064", "1874"])

        XCTAssertEqual(parsed.windowID, 24889)
        XCTAssertEqual(parsed.frame, CGRect(x: -1072, y: -88, width: 1064, height: 1874))
        XCTAssertEqual(parsed.order, .sizePositionSize)
        XCTAssertEqual(parsed.outputPath, "/tmp/hyprmac-probe-frame.txt")
    }

    func testOrderAndOutputPathOverrides() throws {
        let parsed = try parse(["--probe-frame", "7", "0", "0", "800", "600",
                                "--order", "position-size", "--out", "/tmp/probe.txt"])

        XCTAssertEqual(parsed.order, .positionSize)
        XCTAssertEqual(parsed.outputPath, "/tmp/probe.txt")
    }

    func testEveryOrderNamesItsWriteSequence() {
        XCTAssertEqual(ProbeFrameArguments.Order.sizePositionSize.steps,
                       [.size, .position, .size])
        XCTAssertEqual(ProbeFrameArguments.Order.positionSize.steps, [.position, .size])
        XCTAssertEqual(ProbeFrameArguments.Order.sizeOnly.steps, [.size])
    }

    func testLaunchServicesArgumentsAreIgnoredButTyposAreNot() throws {
        let parsed = try parse(["/path/HyprMac Debug", "-psn_0_884321",
                                "--probe-frame", "7", "0", "0", "800", "600",
                                "-NSDocumentRevisionsDebugMode", "YES",
                                "--order", "size-only"])
        XCTAssertEqual(parsed.order, .sizeOnly)

        XCTAssertEqual(failure(["--probe-frame", "7", "0", "0", "800", "600", "--ordr", "size-only"]),
                       .unknownFlag("--ordr"))
    }

    func testEveryRejection() {
        XCTAssertEqual(failure(["--probe-frame", "7", "0", "0", "800"]), .missingValues)
        XCTAssertEqual(failure(["--probe-frame", "window", "0", "0", "800", "600"]),
                       .invalidWindowID("window"))
        XCTAssertEqual(failure(["--probe-frame", "7", "0", "0", "wide", "600"]),
                       .invalidNumber("wide"))
        XCTAssertEqual(failure(["--probe-frame", "7", "0", "0", "0", "600"]), .emptySize)
        XCTAssertEqual(failure(["--probe-frame", "7", "0", "0", "800", "600",
                                "--order", "size-then-position"]),
                       .unknownOrder("size-then-position"))
        XCTAssertEqual(failure(["--probe-frame", "7", "0", "0", "800", "600", "--out"]),
                       .missingValue("--out"))
    }

    // MARK: - new options

    func testWrapperAndRestoreAreOffByDefaultAndOptIn() throws {
        let plain = try parse(["--probe-frame", "7", "0", "0", "800", "600"])
        XCTAssertFalse(plain.wrapper)
        XCTAssertFalse(plain.restore)

        let opted = try parse(["--probe-frame", "7", "0", "0", "800", "600",
                               "--wrapper", "--restore", "--order", "position-size"])
        XCTAssertTrue(opted.wrapper)
        XCTAssertTrue(opted.restore)
        XCTAssertEqual(opted.order, .positionSize)
        XCTAssertEqual(opted.outputPath, "/tmp/hyprmac-probe-frame.txt")
    }

    func testNewFlagsTakeNoValueAndTyposStillFail() {
        XCTAssertEqual(failure(["--probe-frame", "7", "0", "0", "800", "600", "--wrappr"]),
                       .unknownFlag("--wrappr"))
        XCTAssertEqual(failure(["--probe-frame", "7", "0", "0", "800", "600", "--restor"]),
                       .unknownFlag("--restor"))
    }

    // MARK: - probe execution

    private final class FakeProbe {
        var trusted = true
        var pid: pid_t? = 501
        var frame = CGRect(x: 40, y: 40, width: 900, height: 700)
        var minimum: CGSize? = CGSize(width: 400, height: 260)
        var operations: [String] = []
        var writeErrors: [AXError] = []
        var readError: AXError = .success
        var beginResult: AXFrameWriteBatch.BeginResult = .ready(.noop(windowID: 7))
        var endResult: AXFrameWriteBatch.EndResult = .restored
        var time: TimeInterval = 0

        func make() -> ProbeFrameOperations {
            ProbeFrameOperations(
                trusted: { [unowned self] in trusted },
                resolve: { [unowned self] _ in pid },
                setMessagingTimeout: { _ in .success },
                readPosition: { [unowned self] in
                    operations.append("read-position")
                    return readError == .success ? (.success, frame.origin) : (readError, nil)
                },
                readSize: { [unowned self] in
                    operations.append("read-size")
                    return readError == .success ? (.success, frame.size) : (readError, nil)
                },
                readMinimumSize: { [unowned self] in minimum },
                writeSize: { [unowned self] size in
                    operations.append("write-size:\(Int(size.width))x\(Int(size.height))")
                    if !writeErrors.isEmpty { return writeErrors.removeFirst() }
                    frame.size = size
                    return .success
                },
                writePosition: { [unowned self] point in
                    operations.append("write-position:\(Int(point.x)),\(Int(point.y))")
                    if !writeErrors.isEmpty { return writeErrors.removeFirst() }
                    frame.origin = point
                    return .success
                },
                beginWrapper: { [unowned self] _, _ in
                    operations.append("wrapper-begin")
                    return beginResult
                },
                endWrapper: { [unowned self] _, _ in
                    operations.append("wrapper-end")
                    return endResult
                },
                sleep: { [unowned self] interval in
                    operations.append("sleep:\(interval)")
                    time += interval
                },
                now: { [unowned self] in time },
                screenLines: { _ in ["screen 0: owner=true"] }
            )
        }
    }

    private func probeArguments(restore: Bool = false, wrapper: Bool = false)
        -> ProbeFrameArguments {
        var arguments = ProbeFrameArguments(
            windowID: 7, frame: CGRect(x: 0, y: 0, width: 1064, height: 1874))
        arguments.restore = restore
        arguments.wrapper = wrapper
        return arguments
    }

    func testDefaultProbeWritesNoWrapperAndReadsTwice() {
        let fake = FakeProbe()

        let report = ProbeFrame.execute(probeArguments(), operations: fake.make())

        XCTAssertFalse(report.failed)
        XCTAssertFalse(fake.operations.contains("wrapper-begin"))
        XCTAssertFalse(fake.operations.contains("wrapper-end"))
        XCTAssertEqual(fake.operations.filter { $0.hasPrefix("sleep:") },
                       ["sleep:0.3", "sleep:0.7"])
        XCTAssertEqual(report.lines.filter { $0.hasPrefix("after ") }.count, 2)
        XCTAssertTrue(report.lines.contains("ax minimum=400x260"))
        XCTAssertFalse(report.lines.contains { $0.hasPrefix("restore") })
    }

    func testUnreadableMinimumIsReportedWithoutFailingTheProbe() {
        let fake = FakeProbe()
        fake.minimum = nil

        let report = ProbeFrame.execute(probeArguments(), operations: fake.make())

        XCTAssertFalse(report.failed)
        XCTAssertTrue(report.lines.contains("ax minimum=unreadable"))
    }

    func testWrapperModeBracketsTheWrites() {
        let fake = FakeProbe()

        let report = ProbeFrame.execute(probeArguments(wrapper: true), operations: fake.make())

        XCTAssertFalse(report.failed)
        let bracket = fake.operations.filter {
            $0 == "wrapper-begin" || $0 == "wrapper-end" || $0.hasPrefix("write-")
        }
        XCTAssertEqual(bracket, ["wrapper-begin", "write-size:1064x1874",
                                 "write-position:0,0", "write-size:1064x1874", "wrapper-end"])
    }

    func testWrapperBeginFailureFailsTheProbeAndSkipsCleanup() {
        let fake = FakeProbe()
        fake.beginResult = .failed(.cannotComplete)

        let report = ProbeFrame.execute(probeArguments(wrapper: true), operations: fake.make())

        XCTAssertTrue(report.failed)
        XCTAssertFalse(fake.operations.contains("wrapper-end"))
        XCTAssertTrue(report.lines.contains("wrapper begin err=\(AXError.cannotComplete.rawValue)"))
    }

    func testRestorationRunsLastAndTargetsTheBaselineFrame() {
        let fake = FakeProbe()
        let baseline = fake.frame

        let report = ProbeFrame.execute(probeArguments(restore: true), operations: fake.make())

        XCTAssertFalse(report.failed)
        let writes = fake.operations.filter { $0.hasPrefix("write-") }
        XCTAssertEqual(writes, ["write-size:1064x1874", "write-position:0,0",
                                "write-size:1064x1874",
                                "write-size:900x700", "write-position:40,40",
                                "write-size:900x700"])
        XCTAssertEqual(fake.frame, baseline)
        XCTAssertTrue(report.lines.contains("restore result=ok"))
        XCTAssertEqual(report.lines.last, "restore result=ok")
    }

    func testFailedRestorationFailsTheProbeOnItsOwn() {
        let fake = FakeProbe()
        // three clean probe writes, then the first restoration write refuses
        fake.writeErrors = [.success, .success, .success, .cannotComplete]

        let report = ProbeFrame.execute(probeArguments(restore: true), operations: fake.make())

        XCTAssertTrue(report.failed)
        XCTAssertTrue(report.lines.contains("restore result=error"))
        XCTAssertTrue(report.lines.contains(
            "restore write size err=\(AXError.cannotComplete.rawValue)"))
    }

    func testUnreadableBaselineRefusesToRestore() {
        let fake = FakeProbe()
        fake.readError = .cannotComplete

        let report = ProbeFrame.execute(probeArguments(restore: true), operations: fake.make())

        XCTAssertTrue(report.failed)
        XCTAssertTrue(report.lines.contains("restore: skipped, no readable baseline"))
        XCTAssertFalse(fake.operations.contains("write-position:40,40"))
    }

    func testMissingWindowFailsBeforeAnyWrite() {
        let fake = FakeProbe()
        fake.pid = nil

        let report = ProbeFrame.execute(probeArguments(restore: true), operations: fake.make())

        XCTAssertTrue(report.failed)
        XCTAssertTrue(fake.operations.isEmpty)
    }

    private func parse(_ arguments: [String],
                       file: StaticString = #filePath,
                       line: UInt = #line) throws -> ProbeFrameArguments {
        let result = try XCTUnwrap(ProbeFrameArguments.parse(arguments), file: file, line: line)
        switch result {
        case let .success(parsed): return parsed
        case let .failure(reason):
            XCTFail("unexpected rejection: \(reason)", file: file, line: line)
            throw reason
        }
    }

    private func failure(_ arguments: [String],
                         file: StaticString = #filePath,
                         line: UInt = #line) -> ProbeFrameArguments.Failure? {
        switch ProbeFrameArguments.parse(arguments) {
        case let .failure(reason): return reason
        default:
            XCTFail("expected a rejection", file: file, line: line)
            return nil
        }
    }
}
#endif
