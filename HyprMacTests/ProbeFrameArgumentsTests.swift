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
