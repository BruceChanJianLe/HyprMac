import Cocoa
import XCTest
@testable import HyprMac

final class TiledDragEventTests: XCTestCase {
    func testPointUsesSyntheticCGEventLocation() throws {
        let event = try makeEvent(type: .leftMouseDragged, point: CGPoint(x: 123, y: 456))

        XCTAssertEqual(TiledDragEvent.point(event: event, primaryHeight: 900),
                       CGPoint(x: 123, y: 456))
    }

    func testReleaseUsesMouseUpPointRatherThanMouseDownPoint() throws {
        let down = try makeEvent(type: .leftMouseDown, point: CGPoint(x: 10, y: 20))
        let up = try makeEvent(type: .leftMouseUp, point: CGPoint(x: 310, y: 420))

        XCTAssertEqual(TiledDragEvent.point(event: down, primaryHeight: 900),
                       CGPoint(x: 10, y: 20))
        XCTAssertEqual(TiledDragEvent.release(event: up, primaryHeight: 900,
                                              sawDragEvent: true).pointer,
                       CGPoint(x: 310, y: 420))
    }

    func testOptionComesFromReleaseEvent() throws {
        let withoutOption = try makeEvent(type: .leftMouseUp, point: .zero)
        let withOption = try makeEvent(type: .leftMouseUp, point: .zero, optionDown: true)

        XCTAssertFalse(TiledDragEvent.release(event: withoutOption, primaryHeight: 900,
                                              sawDragEvent: true).optionDown)
        XCTAssertTrue(TiledDragEvent.release(event: withOption, primaryHeight: 900,
                                             sawDragEvent: true).optionDown)
    }

    func testReleasePreservesWhetherDragEventWasObserved() throws {
        let event = try makeEvent(type: .leftMouseUp, point: .zero)

        XCTAssertFalse(TiledDragEvent.release(event: event, primaryHeight: 900,
                                              sawDragEvent: false).sawDragEvent)
        XCTAssertTrue(TiledDragEvent.release(event: event, primaryHeight: 900,
                                             sawDragEvent: true).sawDragEvent)
    }

    private func makeEvent(type: CGEventType, point: CGPoint,
                           optionDown: Bool = false) throws -> NSEvent {
        let mouseType: CGMouseButton = .left
        let cgEvent = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: type,
                                           mouseCursorPosition: point, mouseButton: mouseType))
        if optionDown { cgEvent.flags = .maskAlternate }
        return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
    }
}
