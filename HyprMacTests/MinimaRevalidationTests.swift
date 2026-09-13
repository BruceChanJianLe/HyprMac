import XCTest
@testable import HyprMac

// pins MinimaRevalidation: what an explicit request does about a refusal that
// only learned bounds produced, and the markers that carry that request to a
// hidden workspace's reveal. One attempt per request, and a marker that dies
// on every path the user can take instead.

final class MinimaRevalidationTests: XCTestCase {

    private var revalidation: MinimaRevalidation!
    private var screen: NSScreen!
    private var sourceScreen: NSScreen!
    private var assignments: [CGWindowID: Int] = [:]
    private var floating: Set<CGWindowID> = []

    override func setUpWithError() throws {
        guard let main = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("no NSScreen available — test requires a display")
        }
        screen = main
        sourceScreen = main
        assignments = [:]
        floating = []
        revalidation = MinimaRevalidation()
        revalidation.workspaceFor = { [weak self] in self?.assignments[$0] }
        revalidation.isFloating = { [weak self] in self?.floating.contains($0) ?? false }
    }

    private func park(_ id: CGWindowID, to workspace: Int, from source: Int = 3) {
        assignments[id] = workspace
        revalidation.park(id, toWorkspace: workspace, screen: screen,
                          sourceWorkspace: source, sourceScreen: sourceScreen)
    }

    // MARK: - the decision

    func testAFittingDestinationIsAdmittedWithoutRevalidation() {
        XCTAssertEqual(MinimaRevalidation.decide(.fits, destinationVisible: true), .admit)
        XCTAssertEqual(MinimaRevalidation.decide(.fits, destinationVisible: false), .admit)
    }

    func testARefusalNoBypassCanChangeIsRefusedWhereverTheDestinationIs() {
        XCTAssertEqual(MinimaRevalidation.decide(.refused([]), destinationVisible: true), .refuse)
        XCTAssertEqual(MinimaRevalidation.decide(.refused([]), destinationVisible: false), .refuse)
    }

    func testAVisibleDestinationSettlesALearnedRefusalOnTheSpot() {
        XCTAssertEqual(MinimaRevalidation.decide(.revalidatable([]), destinationVisible: true),
                       .revalidateHere)
    }

    func testAHiddenDestinationWaitsForItsReveal() {
        XCTAssertEqual(MinimaRevalidation.decide(.revalidatable([]), destinationVisible: false),
                       .parkForReveal)
    }

    // MARK: - markers

    func testAParkedMoveIsDueOnTheRevealOfItsOwnWorkspace() {
        park(26, to: 2)

        XCTAssertEqual(revalidation.incomingIDs(forWorkspace: 2, screen: screen), [26])
        XCTAssertTrue(revalidation.incomingIDs(forWorkspace: 4, screen: screen).isEmpty)
    }

    func testTheMarkerRecordsWhereTheWindowCameFrom() throws {
        park(26, to: 2, from: 3)

        let marker = try XCTUnwrap(revalidation.marker(for: 26))
        XCTAssertEqual(marker.workspace, 2)
        XCTAssertEqual(marker.sourceWorkspace, 3)
        XCTAssertEqual(marker.sourceScreen, sourceScreen)
    }

    func testAskingAgainReplacesTheMarkerRatherThanKeepingBoth() {
        park(26, to: 2)
        park(26, to: 4)

        XCTAssertEqual(revalidation.pendingWindowIDs, [26])
        XCTAssertEqual(revalidation.marker(for: 26)?.workspace, 4)
        XCTAssertTrue(revalidation.incomingIDs(forWorkspace: 2, screen: screen).isEmpty)
    }

    func testTheMarkerIsSpentOnTheRevealWhenTheAttemptIsAccepted() {
        park(26, to: 2)
        let due = revalidation.incomingIDs(forWorkspace: 2, screen: screen)

        revalidation.noteReveal(due, accepted: [26])

        XCTAssertTrue(revalidation.pendingWindowIDs.isEmpty)
    }

    func testTheMarkerIsSpentOnTheRevealWhenTheAttemptIsRefusedToo() {
        park(26, to: 2)
        let due = revalidation.incomingIDs(forWorkspace: 2, screen: screen)

        revalidation.noteReveal(due, accepted: [])

        XCTAssertTrue(revalidation.pendingWindowIDs.isEmpty,
                      "a refused reveal hands the window to the bounded recovery,"
                      + " it does not earn a second bypass")
        XCTAssertTrue(revalidation.incomingIDs(forWorkspace: 2, screen: screen).isEmpty)
    }

    func testARevealOfAnotherWorkspaceSpendsNothing() {
        park(26, to: 2)

        let due = revalidation.incomingIDs(forWorkspace: 4, screen: screen)
        revalidation.noteReveal(due, accepted: [])

        XCTAssertEqual(revalidation.pendingWindowIDs, [26])
    }

    // MARK: - cancellation

    func testAWindowMovedAgainDropsItsMarkerAtTheReveal() {
        park(26, to: 2)
        assignments[26] = 5

        XCTAssertTrue(revalidation.incomingIDs(forWorkspace: 2, screen: screen).isEmpty)
        XCTAssertTrue(revalidation.pendingWindowIDs.isEmpty)
    }

    func testAWindowTheUserFloatedDropsItsMarkerAtTheReveal() {
        park(26, to: 2)
        floating.insert(26)

        XCTAssertTrue(revalidation.incomingIDs(forWorkspace: 2, screen: screen).isEmpty)
        XCTAssertTrue(revalidation.pendingWindowIDs.isEmpty)
    }

    func testAnExplicitCancelDropsOneMarkerAndLeavesTheRest() {
        park(26, to: 2)
        park(27, to: 2)

        revalidation.cancel(26, reason: "moved again")

        XCTAssertEqual(revalidation.pendingWindowIDs, [27])
    }

    func testCancelAllDropsEveryMarker() {
        park(26, to: 2)
        park(27, to: 4)

        revalidation.cancelAll(reason: "display change")

        XCTAssertTrue(revalidation.pendingWindowIDs.isEmpty)
    }

    func testForgettingAClosedWindowDropsItsMarker() {
        park(26, to: 2)

        revalidation.forget(26)

        XCTAssertTrue(revalidation.pendingWindowIDs.isEmpty)
    }

    func testCancellingAWindowThatHasNoMarkerIsHarmless() {
        park(26, to: 2)

        revalidation.cancel(99, reason: "moved again")

        XCTAssertEqual(revalidation.pendingWindowIDs, [26])
    }
}
