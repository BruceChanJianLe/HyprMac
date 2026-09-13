import XCTest
@testable import HyprMac

// DebugLogFileTests pin the on-disk contract: the line format the docs
// promise, rotation at the byte ceiling, and the never-crash guarantee
// when the destination directory is unusable. Every case writes into its
// own temp directory so the suite never touches ~/Library/Logs.

final class DebugLogFileTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebugLogFileTests.\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: - line format

    func testAppendedLinesUseTheDocumentedFormat() throws {
        let log = DebugLogFile(directory: dir, fileName: "format.log")
        XCTAssertTrue(log.isAvailable)

        log.append(level: .notice, category: .discovery, message: "window gone: 42")
        log.append(level: .debug, category: .lifecycle, message: "started")
        log.flush()

        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix(" [notice] [discovery] window gone: 42"), lines[0])
        XCTAssertTrue(lines[1].hasSuffix(" [debug] [lifecycle] started"), lines[1])

        // 2026-09-12T19:41:02.123-0500
        let stamp = String(lines[0].prefix(while: { $0 != " " }))
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{4}$"#
        XCTAssertNotNil(stamp.range(of: pattern, options: .regularExpression), stamp)
    }

    func testEveryCategoryAndLevelReachesTheFile() throws {
        let log = DebugLogFile(directory: dir, fileName: "all.log")
        for level in [LogLevel.debug, .info, .notice, .warning, .error, .fault] {
            log.append(level: level, category: .tiling, message: "l")
        }
        log.flush()

        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        for name in ["debug", "info", "notice", "warning", "error", "fault"] {
            XCTAssertTrue(text.contains("[\(name)] [tiling] l"), name)
        }
    }

    // MARK: - rotation

    func testRotationArchivesAndRestartsTheFile() throws {
        // one formatted line here is 56 bytes, so the ceiling is crossed
        // on the second append and again on the fourth.
        let log = DebugLogFile(directory: dir, fileName: "rotate.log", maxBytes: 64)
        let archive = log.fileURL.appendingPathExtension("1")

        log.append(level: .notice, category: .discovery, message: "alpha")
        log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))

        log.append(level: .notice, category: .discovery, message: "bravo")
        log.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        let archived = try String(contentsOf: archive, encoding: .utf8)
        XCTAssertTrue(archived.contains("alpha"))
        XCTAssertTrue(archived.contains("bravo"))
        XCTAssertEqual(try String(contentsOf: log.fileURL, encoding: .utf8), "")

        log.append(level: .notice, category: .discovery, message: "charl")
        log.flush()
        let current = try String(contentsOf: log.fileURL, encoding: .utf8)
        XCTAssertTrue(current.contains("charl"))
        XCTAssertFalse(current.contains("alpha"))
    }

    func testRotationReplacesThePreviousArchive() throws {
        let log = DebugLogFile(directory: dir, fileName: "replace.log", maxBytes: 64)
        let archive = log.fileURL.appendingPathExtension("1")

        for message in ["alpha", "bravo", "charl", "delta"] {
            log.append(level: .notice, category: .discovery, message: message)
        }
        log.flush()

        let archived = try String(contentsOf: archive, encoding: .utf8)
        XCTAssertFalse(archived.contains("alpha"))
        XCTAssertTrue(archived.contains("charl"))
        XCTAssertTrue(archived.contains("delta"))
    }

    // MARK: - failure is silent

    func testUnusableDirectoryDisablesTheLogInsteadOfCrashing() {
        let log = DebugLogFile(directory: URL(fileURLWithPath: "/dev/null/nowhere", isDirectory: true),
                               fileName: "nope.log")
        XCTAssertFalse(log.isAvailable)
        log.append(level: .error, category: .lifecycle, message: "dropped")
        log.flush()
    }
}
