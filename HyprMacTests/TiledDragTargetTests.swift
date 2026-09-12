import XCTest
@testable import HyprMac

final class TiledDragTargetTests: XCTestCase {
    private let slots: [CGWindowID: CGRect] = [
        1: CGRect(x: 0, y: 0, width: 100, height: 80),
        2: CGRect(x: 110, y: 0, width: 100, height: 80),
        3: CGRect(x: 220, y: 0, width: 100, height: 80),
        4: CGRect(x: 330, y: 0, width: 100, height: 80)
    ]

    func testSelectsEachNormalizedNearestEdge() {
        XCTAssertEqual(resolve(CGPoint(x: 111, y: 40)), target(2, .left))
        XCTAssertEqual(resolve(CGPoint(x: 209, y: 40)), target(2, .right))
        XCTAssertEqual(resolve(CGPoint(x: 160, y: 1)), target(2, .top))
        XCTAssertEqual(resolve(CGPoint(x: 160, y: 79)), target(2, .bottom))
    }

    func testIncludesExactSlotEdges() {
        XCTAssertEqual(resolve(CGPoint(x: 110, y: 40)), target(2, .left))
        XCTAssertEqual(resolve(CGPoint(x: 210, y: 40)), target(2, .right))
        XCTAssertEqual(resolve(CGPoint(x: 160, y: 0)), target(2, .top))
        XCTAssertEqual(resolve(CGPoint(x: 160, y: 80)), target(2, .bottom))
    }

    func testTiesUseLeftRightTopBottomOrder() {
        XCTAssertEqual(resolve(CGPoint(x: 160, y: 40)), target(2, .left))
        XCTAssertEqual(resolve(CGPoint(x: 135, y: 40)), target(2, .left))
        XCTAssertEqual(resolve(CGPoint(x: 185, y: 40)), target(2, .right))
    }

    func testHitsEveryColumnByPointerLocation() {
        for id: CGWindowID in 1...4 {
            guard let frame = slots[id] else { return XCTFail("missing fixture slot") }
            XCTAssertEqual(resolve(CGPoint(x: frame.midX, y: 2), draggedID: 99)?.windowID, id)
        }
    }

    func testExcludesDraggedSlotAndDoesNotUseDraggedFinalCenter() {
        var candidates = slots
        candidates[9] = CGRect(x: 100, y: -10, width: 130, height: 100)
        XCTAssertEqual(resolve(CGPoint(x: 160, y: 2), draggedID: 9,
                               intendedSlots: candidates), target(2, .top))
    }

    func testOutsideAndNonFinitePointersHaveNoTarget() {
        XCTAssertNil(resolve(CGPoint(x: -1, y: 40)))
        XCTAssertNil(resolve(CGPoint(x: CGFloat.nan, y: 40)))
        XCTAssertNil(resolve(CGPoint(x: 160, y: CGFloat.infinity)))
    }

    func testAmbiguousOverlappingSlotsHaveNoTarget() {
        let overlapping: [CGWindowID: CGRect] = [
            2: CGRect(x: 0, y: 0, width: 100, height: 100),
            3: CGRect(x: 50, y: 0, width: 100, height: 100)
        ]
        XCTAssertNil(resolve(CGPoint(x: 75, y: 50), intendedSlots: overlapping))
    }

    private func resolve(_ pointer: CGPoint, draggedID: CGWindowID = 1,
                         intendedSlots: [CGWindowID: CGRect]? = nil) -> TiledDragTarget? {
        TiledDragTargetResolver.resolve(pointer: pointer, draggedID: draggedID,
                                        intendedSlots: intendedSlots ?? slots)
    }

    private func target(_ windowID: CGWindowID, _ edge: BSPTargetEdge) -> TiledDragTarget {
        TiledDragTarget(windowID: windowID, edge: edge)
    }
}
