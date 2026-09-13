import XCTest
@testable import HyprMac

// DestroyRecheckTests pin the bounded re-poll that follows a destroy
// notification whose poll saw nothing gone yet.

final class DestroyRecheckTests: XCTestCase {

    func testDestroyResolvedByAGoneWindowOwnedByThatPID() {
        var recheck = DestroyRecheck()
        recheck.noteDestroy(pid: 7)

        let again = recheck.resolve(goneIDs: [100], ownersBefore: [100: 7], runningPIDs: [7])

        XCTAssertFalse(again)
        XCTAssertTrue(recheck.pending.isEmpty)
    }

    func testUnresolvedDestroyRepollsUntilTheAttemptBudgetRunsOut() {
        var recheck = DestroyRecheck()
        recheck.noteDestroy(pid: 7)

        for attempt in 1..<DestroyRecheck.maxAttempts {
            let again = recheck.resolve(goneIDs: [], ownersBefore: [100: 7], runningPIDs: [7])
            XCTAssertTrue(again, "attempt \(attempt) should still ask for another poll")
        }

        let last = recheck.resolve(goneIDs: [], ownersBefore: [100: 7], runningPIDs: [7])
        XCTAssertFalse(last)
        XCTAssertTrue(recheck.pending.isEmpty)
    }

    func testDeadPIDIsDroppedImmediately() {
        var recheck = DestroyRecheck()
        recheck.noteDestroy(pid: 7)

        let again = recheck.resolve(goneIDs: [], ownersBefore: [100: 7], runningPIDs: [])

        XCTAssertFalse(again)
        XCTAssertTrue(recheck.pending.isEmpty)
    }

    func testPIDWithNoKnownWindowIsDroppedImmediately() {
        var recheck = DestroyRecheck()
        recheck.noteDestroy(pid: 7)

        let again = recheck.resolve(goneIDs: [], ownersBefore: [100: 9], runningPIDs: [7, 9])

        XCTAssertFalse(again)
        XCTAssertTrue(recheck.pending.isEmpty)
    }

    func testOneSatisfiedPIDStillLeavesTheOtherWaiting() {
        var recheck = DestroyRecheck()
        recheck.noteDestroy(pid: 7)
        recheck.noteDestroy(pid: 8)

        let again = recheck.resolve(goneIDs: [100], ownersBefore: [100: 7, 200: 8], runningPIDs: [7, 8])

        XCTAssertTrue(again)
        XCTAssertEqual(Array(recheck.pending.keys), [8])
    }

    func testNewDestroyResetsTheAttemptBudget() {
        var recheck = DestroyRecheck()
        let owners: [CGWindowID: pid_t] = [10: 7]
        recheck.noteDestroy(pid: 7)
        XCTAssertTrue(recheck.resolve(goneIDs: [], ownersBefore: owners, runningPIDs: [7]))
        XCTAssertTrue(recheck.resolve(goneIDs: [], ownersBefore: owners, runningPIDs: [7]))
        // a second close arrives before the first budget is spent
        recheck.noteDestroy(pid: 7)
        XCTAssertEqual(recheck.pending[7], 0)
        XCTAssertTrue(recheck.resolve(goneIDs: [], ownersBefore: owners, runningPIDs: [7]))
        XCTAssertTrue(recheck.resolve(goneIDs: [], ownersBefore: owners, runningPIDs: [7]))
        XCTAssertFalse(recheck.resolve(goneIDs: [], ownersBefore: owners, runningPIDs: [7]))
    }
}
