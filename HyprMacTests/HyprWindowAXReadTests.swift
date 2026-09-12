import XCTest
@testable import HyprMac

final class HyprWindowAXReadTests: XCTestCase {
    private final class ScriptedWindow: HyprWindow {
        var scriptedPosition: (AXError, CGPoint?) = (.success, nil)
        var scriptedSize: (AXError, CGSize?) = (.success, nil)

        override func readPosition() -> (AXError, CGPoint?) {
            scriptedPosition
        }

        override func readSize() -> (AXError, CGSize?) {
            scriptedSize
        }
    }

    func testPublicFrameDelegatesToTypedReadsAndFailsClosed() {
        let window = ScriptedWindow(
            element: AXUIElementCreateApplication(0), windowID: 50, ownerPID: 0
        )
        let expected = CGRect(x: 12, y: 34, width: 640, height: 480)
        window.scriptedPosition = (.success, expected.origin)
        window.scriptedSize = (.success, expected.size)
        XCTAssertEqual(window.position, expected.origin)
        XCTAssertEqual(window.size, expected.size)
        XCTAssertEqual(window.frame, expected)

        window.scriptedPosition = (.cannotComplete, nil)
        XCTAssertNil(window.position)
        XCTAssertNil(window.frame)
        window.scriptedPosition = (.success, expected.origin)
        window.scriptedSize = (.failure, nil)
        XCTAssertNil(window.size)
        XCTAssertNil(window.frame)
    }
}
