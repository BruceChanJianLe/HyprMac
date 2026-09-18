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

    func testVisibleNumericDestinationStaysLiveWhileHiddenDestinationParks() {
        let plan = RetileAllPlan(assignments: [3: [30], 4: [40]], overflow: [])
        var assigned: [CGWindowID: Int] = [:]
        var parked: [(CGWindowID, Int)] = []

        RetileAllPlanner.applyAdmission(
            plan,
            isWorkspaceVisible: { $0 == 3 },
            assign: { assigned[$0] = $1 },
            park: { parked.append(($0, $1)) }
        )

        XCTAssertEqual(assigned, [30: 3, 40: 4])
        XCTAssertEqual(parked.map { [$0.0, CGWindowID($0.1)] }, [[40, 4]])
    }

    func testAdmissionPreservesParkedAssignmentsAndSkipsFloatingOccupancy() {
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
        XCTAssertEqual(result.assignments[2], [100, 101], "floating ids do not consume tile capacity")
        XCTAssertTrue(result.overflow.isEmpty)
    }

    func testAssignedHiddenWindowsStillConsumeWorkspaceCapacity() {
        let exclusions = ActionDispatcher.admissionExclusions(
            floatingWindowIDs: [],
            hiddenWindowIDs: [10, 11, 12, 13],
            reservedHiddenWindowIDs: [10, 11, 12, 13]
        )
        let result = RetileAllPlanner.admit(
            windowIDs: [100, 101],
            preferredWorkspace: 1,
            eligibleWorkspaces: [1, 2],
            existingAssignments: [1: [10, 11, 12, 13]],
            excludedWindowIDs: exclusions,
            capacityForWorkspace: { _ in 4 }
        )

        XCTAssertNil(result.assignments[1])
        XCTAssertEqual(result.assignments[2], [100, 101])
    }

    func testClosedHiddenWindowsDoNotConsumeFocusedWorkspaceCapacity() {
        // closed-but-app-alive ghosts hold no tile slot, so a half-full
        // workspace still admits the new window instead of spilling.
        let exclusions = ActionDispatcher.admissionExclusions(
            floatingWindowIDs: [],
            hiddenWindowIDs: [20, 21],
            reservedHiddenWindowIDs: []
        )
        let result = RetileAllPlanner.admit(
            windowIDs: [100],
            preferredWorkspace: 2,
            eligibleWorkspaces: [2, 4, 6, 8],
            existingAssignments: [2: [10, 11, 20, 21], 4: []],
            excludedWindowIDs: exclusions,
            capacityForWorkspace: { _ in 4 }
        )

        XCTAssertEqual(result.assignments[2], [100])
        XCTAssertNil(result.assignments[4])
        XCTAssertTrue(result.overflow.isEmpty)
    }

    func testAdmissionUsesNextNumericWorkspaceAcrossMonitorHomes() {
        let result = RetileAllPlanner.admit(
            windowIDs: [100, 101, 102],
            preferredWorkspace: 2,
            eligibleWorkspaces: Array(1...9),
            existingAssignments: [2: [20, 21], 3: [30]],
            excludedWindowIDs: [],
            capacityForWorkspace: { _ in 2 }
        )

        XCTAssertEqual(result.assignments[3], [100])
        XCTAssertEqual(result.assignments[4], [101, 102])
        XCTAssertNil(result.assignments[5], "ws2 overflow must use ws3 before ws4")
        XCTAssertTrue(result.overflow.isEmpty)
    }

    func testAdmissionWrapsFromWorkspaceNineToOne() {
        let result = RetileAllPlanner.admit(
            windowIDs: [100],
            preferredWorkspace: 9,
            eligibleWorkspaces: Array(1...9),
            existingAssignments: [9: [90]],
            excludedWindowIDs: [],
            capacityForWorkspace: { _ in 1 }
        )

        XCTAssertEqual(result.assignments[1], [100])
        XCTAssertTrue(result.overflow.isEmpty)
    }

    func testAdmissionReportsOverflowOnlyWhenAllNumericWorkspacesAreFull() {
        let result = RetileAllPlanner.admit(
            windowIDs: [100],
            preferredWorkspace: 2,
            eligibleWorkspaces: Array(1...9),
            existingAssignments: Dictionary<Int, Set<CGWindowID>>(uniqueKeysWithValues: (1...9).map {
                ($0, [CGWindowID($0)])
            }),
            excludedWindowIDs: [],
            capacityForWorkspace: { _ in 1 }
        )

        XCTAssertEqual(result.assignments[2], [100])
        XCTAssertEqual(result.overflow, [100])
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

    func testStartupWorkspaceOrderPlacesVisibleWorkspacesFirst() {
        XCTAssertEqual(
            RetileAllPlanner.startupWorkspaceOrder(
                visibleWorkspaces: [5, 2],
                eligibleWorkspaces: [1, 2, 3, 4, 5]
            ),
            [5, 2, 1, 3, 4]
        )
    }

    func testStartupPackingReservesCapacityForAssignedHiddenWindows() {
        let assignments: [Int: Set<CGWindowID>] = [1: [10, 11], 2: []]
        let hidden: Set<CGWindowID> = [10, 11]
        let result = RetileAllPlanner.pack(
            windowIDs: [100, 101, 102],
            workspaceOrder: [1, 2]
        ) { workspace in
            RetileAllPlanner.availableStartupCapacity(
                capacity: 4,
                assignedWindowIDs: assignments[workspace, default: []],
                reservedHiddenWindowIDs: hidden,
                floatingWindowIDs: []
            )
        }

        XCTAssertEqual(result.assignments[1], [100, 101])
        XCTAssertEqual(result.assignments[2], [102])
        XCTAssertTrue(result.overflow.isEmpty)
    }

    func testStartupCapacityOnlyReservesForReservableHiddenWindows() {
        // only the hidden id that can come back on its own holds a slot.
        XCTAssertEqual(
            RetileAllPlanner.availableStartupCapacity(
                capacity: 4,
                assignedWindowIDs: [1, 2, 3, 4],
                reservedHiddenWindowIDs: [3],
                floatingWindowIDs: []
            ),
            3
        )
    }

    func testStartupWindowOrderUsesFrameOrderWithFocusedWindowFirst() {
        let result = RetileAllPlanner.startupWindowOrder(
            windowIDs: [40, 10, 30, 20],
            framesByID: [
                10: CGRect(x: 900, y: 20, width: 100, height: 100),
                20: CGRect(x: 100, y: 80, width: 100, height: 100),
                30: CGRect(x: 100, y: 20, width: 100, height: 100)
            ],
            focusedWindowID: 10
        )

        XCTAssertEqual(result, [10, 30, 20, 40])
    }

    func testStartupFillsEachVisibleHomeBeforeNumericCrossMonitorOverflow() {
        let result = RetileAllPlanner.admitStartupBatches(
            [
                RetileAllBatch(preferredWorkspace: 1, windowIDs: [10, 11, 12]),
                RetileAllBatch(preferredWorkspace: 2, windowIDs: [20, 21])
            ],
            workspaceCount: 5,
            reservedAssignments: [:],
            capacityForWorkspace: { [1: 2, 2: 2, 3: 1, 4: 2, 5: 2][$0] ?? 0 }
        )

        XCTAssertEqual(result.assignments[1], [10, 11])
        XCTAssertEqual(result.assignments[2], [20, 21], "monitor two keeps its fitting windows")
        XCTAssertEqual(result.assignments[3], [12], "workspace one overflow crosses to numeric workspace two's next free successor")
        XCTAssertTrue(result.overflow.isEmpty)
    }

    func testStartupOverflowWrapsAndRespectsReservedHomeCapacity() {
        let result = RetileAllPlanner.admitStartupBatches(
            [RetileAllBatch(preferredWorkspace: 9, windowIDs: [90, 91])],
            workspaceCount: 9,
            reservedAssignments: [9: [900], 1: [100]],
            capacityForWorkspace: { $0 == 2 ? 2 : 1 }
        )

        XCTAssertNil(result.assignments[9])
        XCTAssertNil(result.assignments[1])
        XCTAssertEqual(result.assignments[2], [90, 91])
        XCTAssertTrue(result.overflow.isEmpty)
    }

    func testNextFittingHomeCyclesAfterSourceAndSkipsRejectedHomes() {
        var probed: [Int] = []
        let result = RetileAllPlanner.nextFittingHome(
            after: 3,
            eligibleWorkspaces: [1, 3, 5, 7]
        ) { workspace in
            probed.append(workspace)
            return workspace == 1
        }

        XCTAssertEqual(result, 1)
        XCTAssertEqual(probed, [5, 7, 1])
    }

    func testNextFittingHomeExcludesSourceAndDuplicateHomes() {
        var probed: [Int] = []
        let result = RetileAllPlanner.nextFittingHome(
            after: 3,
            eligibleWorkspaces: [3, 5, 5, 3]
        ) { workspace in
            probed.append(workspace)
            return false
        }

        XCTAssertNil(result)
        XCTAssertEqual(probed, [5])
    }

    func testTenWorkspaceCapacityAndOverflow() {
        let ids = (1...20).map(CGWindowID.init)
        let result = RetileAllPlanner.pack(
            windowIDs: ids,
            workspaceCount: Constants.workspaceCount,
            capacityForWorkspace: { $0.isMultiple(of: 2) ? 1 : 2 }
        )

        XCTAssertEqual(result.assignments.keys.sorted(), Array(Constants.workspaceRange))
        XCTAssertEqual(result.assignments[1], [1, 2])
        XCTAssertEqual(result.assignments[2], [3])
        XCTAssertEqual(result.assignments[9], [13, 14])
        XCTAssertEqual(result.assignments[10], [15])
        XCTAssertEqual(result.overflow, [16, 17, 18, 19, 20])
    }

    func testDisabledMonitorWindowRemainsFloating() {
        XCTAssertTrue(RetileAllPlanner.shouldRemainFloating(isAutoFloat: false, isOnDisabledMonitor: true))
        XCTAssertTrue(RetileAllPlanner.shouldRemainFloating(isAutoFloat: true, isOnDisabledMonitor: false))
        XCTAssertFalse(RetileAllPlanner.shouldRemainFloating(isAutoFloat: false, isOnDisabledMonitor: false))
    }
}
