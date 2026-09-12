import XCTest
@testable import HyprMac

final class RetileAllPlannerTests: XCTestCase {
    func testDepthTwoCapacityIsFour() {
        XCTAssertEqual(RetileAllPlanner.workspaceCapacity(maxDepth: 2), 4)
    }

    func testLateBatchFillsPreferredWorkspaceThenParksOnNextHomeWorkspace() {
        let result = RetileAllPlanner.admit(
            windowIDs: [1, 2, 3, 4, 5],
            preferredWorkspace: 1,
            eligibleWorkspaces: [1, 2, 3],
            existingAssignments: [:],
            excludedWindowIDs: [],
            capacityForWorkspace: { _ in 4 }
        )

        XCTAssertEqual(result.assignments[1], [1, 2, 3, 4])
        XCTAssertEqual(result.assignments[2], [5])
        XCTAssertTrue(result.overflow.isEmpty)

        var assigned: [CGWindowID: Int] = [:]
        var parked: [(CGWindowID, Int)] = []
        RetileAllPlanner.applyAdmission(
            result,
            isWorkspaceVisible: { $0 == 1 },
            assign: { assigned[$0] = $1 },
            park: { parked.append(($0, $1)) }
        )
        XCTAssertEqual(assigned, [1: 1, 2: 1, 3: 1, 4: 1, 5: 2])
        XCTAssertEqual(parked.map { [$0.0, CGWindowID($0.1)] }, [[5, 2]])
    }

    func testAdmissionPreservesParkedAssignmentsAndSkipsExcludedOccupancy() {
        let existing: [Int: Set<CGWindowID>] = [
            1: [10, 11, 12, 13],
            2: [20, 21, 22],
            4: [40]
        ]
        let result = RetileAllPlanner.admit(
            windowIDs: [100, 101],
            preferredWorkspace: 1,
            eligibleWorkspaces: [1, 2, 3],
            existingAssignments: existing,
            excludedWindowIDs: [22],
            capacityForWorkspace: { _ in 4 }
        )

        XCTAssertEqual(existing[4], [40], "planner must not rewrite parked regular workspaces")
        XCTAssertEqual(result.assignments[2], [100, 101], "excluded minimized/floating ids do not consume tile capacity")
        XCTAssertTrue(result.overflow.isEmpty)
    }

    func testAdmissionCyclesFromPreferredAndStaysOnEligibleMonitorHomes() {
        let result = RetileAllPlanner.admit(
            windowIDs: [100, 101, 102],
            preferredWorkspace: 5,
            eligibleWorkspaces: [1, 3, 5, 7, 9],
            existingAssignments: [5: [50], 7: [70]],
            excludedWindowIDs: [],
            capacityForWorkspace: { _ in 2 }
        )

        XCTAssertEqual(result.assignments[5], [100])
        XCTAssertEqual(result.assignments[7], [101])
        XCTAssertEqual(result.assignments[9], [102])
        XCTAssertNil(result.assignments[2], "admission must not cross to another monitor's workspace")
    }

    func testAdmissionReportsOverflowOnlyWhenEligibleHomesAreFull() {
        let result = RetileAllPlanner.admit(
            windowIDs: [100, 101],
            preferredWorkspace: 1,
            eligibleWorkspaces: [1, 3],
            existingAssignments: [1: [10], 3: [30]],
            excludedWindowIDs: [],
            capacityForWorkspace: { _ in 1 }
        )

        XCTAssertEqual(result.assignments[1], [100, 101], "overflow keeps active workspace membership for existing spill routing")
        XCTAssertEqual(result.overflow, [100, 101])
    }

    func testIncomingFloatingWindowDoesNotConsumeTileCapacity() {
        let result = RetileAllPlanner.admit(
            windowIDs: [100, 101, 102],
            preferredWorkspace: 1,
            eligibleWorkspaces: [1, 2],
            existingAssignments: [1: [10]],
            excludedWindowIDs: [100],
            capacityForWorkspace: { _ in 2 }
        )

        XCTAssertEqual(result.assignments[1], [100, 101])
        XCTAssertEqual(result.assignments[2], [102])
    }

    func testScratchpadMemberIsFilteredBeforeAdmission() {
        let result = ActionDispatcher.newWindowIDsForAdmission(
            [100, 101],
            workspaceFor: { $0 == 100 ? 0 : nil }
        )

        XCTAssertEqual(result, [101])
    }

    func testFullyForgottenIDsAreRemovedFromAdmissionOccupancy() {
        let result = ActionDispatcher.existingAssignmentsForAdmission(
            [1: [10, 11], 2: [20]],
            fullyForgottenIDs: [11]
        )

        XCTAssertEqual(result, [1: [10], 2: [20]])
    }

    func testAdmissionOrderIsStableAndDeduplicated() {
        let first = RetileAllPlanner.admit(
            windowIDs: [5, 2, 5, 3],
            preferredWorkspace: 1,
            eligibleWorkspaces: [1, 2],
            existingAssignments: [:],
            excludedWindowIDs: [],
            capacityForWorkspace: { _ in 2 }
        )
        let shuffled = RetileAllPlanner.admit(
            windowIDs: [3, 5, 2, 5],
            preferredWorkspace: 1,
            eligibleWorkspaces: [1, 2],
            existingAssignments: [:],
            excludedWindowIDs: [],
            capacityForWorkspace: { _ in 2 }
        )

        XCTAssertEqual(first.assignments, [1: [2, 3], 2: [5]])
        XCTAssertEqual(shuffled.assignments, first.assignments)
        XCTAssertTrue(first.overflow.isEmpty)
    }

    func testRecycledIncomingIDDoesNotConsumeOldAndNewCapacity() {
        let result = RetileAllPlanner.admit(
            windowIDs: [100, 101],
            preferredWorkspace: 1,
            eligibleWorkspaces: [1, 2],
            existingAssignments: [1: [10, 100]],
            excludedWindowIDs: [],
            capacityForWorkspace: { _ in 2 }
        )

        XCTAssertEqual(result.assignments[1], [100])
        XCTAssertEqual(result.assignments[2], [101])
    }

    func testEligibleWindowsIncludeHiddenWorkspaceAssignmentsInStableOrder() {
        let assignments: [Int: Set<CGWindowID>] = [
            1: [40, 10],
            2: [30],
            8: [20]
        ]

        let result = RetileAllPlanner.eligibleWindowIDs(
            workspaceAssignments: assignments,
            discoveredWindowIDs: [50, 10],
            excludedWindowIDs: [30]
        )

        XCTAssertEqual(result, [10, 20, 40, 50])
    }

    func testPackingUsesWorkspaceNumberOrderWithoutGaps() {
        let result = RetileAllPlanner.pack(
            windowIDs: [10, 20, 30, 40, 50, 60],
            workspaceCount: 5,
            capacityForWorkspace: { workspace in
                [1: 2, 2: 1, 3: 2, 4: 1, 5: 3][workspace] ?? 0
            }
        )

        XCTAssertEqual(result.assignments[1], [10, 20])
        XCTAssertEqual(result.assignments[2], [30])
        XCTAssertEqual(result.assignments[3], [40, 50])
        XCTAssertEqual(result.assignments[4], [60])
        XCTAssertNil(result.assignments[5])
        XCTAssertTrue(result.overflow.isEmpty)
    }

    func testPackingSkipsUnavailableWorkspaceWithoutLosingWindows() {
        let result = RetileAllPlanner.pack(
            windowIDs: [10, 20, 30],
            workspaceCount: 3,
            capacityForWorkspace: { $0 == 2 ? 0 : 1 }
        )

        XCTAssertEqual(result.assignments, [1: [10], 3: [20]])
        XCTAssertEqual(result.overflow, [30])
    }

    func testVisibleWorkspaceAndFocusDoNotChangePlan() {
        let first = RetileAllPlanner.eligibleWindowIDs(
            workspaceAssignments: [4: [90, 20], 8: [50]],
            discoveredWindowIDs: [90, 20, 50],
            excludedWindowIDs: []
        )
        let afterSwitchAndFocusChange = RetileAllPlanner.eligibleWindowIDs(
            workspaceAssignments: [1: [50], 2: [90], 3: [20]],
            discoveredWindowIDs: [20, 50, 90],
            excludedWindowIDs: []
        )

        XCTAssertEqual(first, [20, 50, 90])
        XCTAssertEqual(afterSwitchAndFocusChange, first)
        XCTAssertEqual(
            RetileAllPlanner.pack(windowIDs: first, workspaceCount: 9, capacityForWorkspace: { _ in 1 }).assignments,
            RetileAllPlanner.pack(windowIDs: afterSwitchAndFocusChange, workspaceCount: 9, capacityForWorkspace: { _ in 1 }).assignments
        )
    }

    func testNineWorkspaceCapacityAndOverflow() {
        let ids = (1...20).map(CGWindowID.init)
        let result = RetileAllPlanner.pack(
            windowIDs: ids,
            workspaceCount: 9,
            capacityForWorkspace: { $0.isMultiple(of: 2) ? 1 : 2 }
        )

        XCTAssertEqual(result.assignments.keys.sorted(), Array(1...9))
        XCTAssertEqual(result.assignments[1], [1, 2])
        XCTAssertEqual(result.assignments[2], [3])
        XCTAssertEqual(result.assignments[9], [13, 14])
        XCTAssertEqual(result.overflow, [15, 16, 17, 18, 19, 20])
    }

    func testDisabledMonitorWindowRemainsFloating() {
        XCTAssertTrue(RetileAllPlanner.shouldRemainFloating(isAutoFloat: false, isOnDisabledMonitor: true))
        XCTAssertTrue(RetileAllPlanner.shouldRemainFloating(isAutoFloat: true, isOnDisabledMonitor: false))
        XCTAssertFalse(RetileAllPlanner.shouldRemainFloating(isAutoFloat: false, isOnDisabledMonitor: false))
    }
}
