import XCTest
@testable import HyprMac

// StateDumpFormatterTests pin the exact shape of the SIGUSR1 / startup
// dump. The formatter is pure — plain names, dicts and id sets in,
// strings out — so the block can be asserted line for line.

final class StateDumpFormatterTests: XCTestCase {

    private func fixture() -> StateDumpFormatter {
        StateDumpFormatter(
            screens: [
                .init(name: "Display A", visibleWorkspace: 1),
                .init(name: "Display B", visibleWorkspace: 2)
            ],
            homeScreenNames: [1: "Display A", 2: "Display B", 3: "Display A", 4: "Display B"],
            visibleWorkspaces: [1, 2],
            assignments: [10: 1, 11: 1, 20: 2, 40: 4, 99: 0],
            hidden: [11, 40],
            reserved: [40],
            floating: [20],
            trees: [1: [10], 4: [40]],
            scratchpad: [99],
            knownCount: 5,
            minima: [20: CGSize(width: 520, height: 360), 10: CGSize(width: 400, height: 260)]
        )
    }

    func testDumpListsScreensThenWorkspacesThenScratchpadThenTotals() {
        XCTAssertEqual(fixture().lines(), [
            "screen=Display A visible=ws1",
            "screen=Display B visible=ws2",
            "ws1 home=Display A visible=true assigned=[10, 11] hidden=[11] reserved=[] floating=[] tree(Display A)=[10]",
            "ws2 home=Display B visible=true assigned=[20] hidden=[] reserved=[] floating=[20] tree(Display B)=[]",
            "ws4 home=Display B visible=false assigned=[40] hidden=[40] reserved=[40] floating=[] tree(Display B)=[40]",
            "scratchpad=[99]",
            "minima=[10:400x260, 20:520x360]",
            "recovery pending=[] unverified=[]",
            "known=5 hidden=2 reserved=1 floating=1"
        ])
    }

    func testWorkspaceWithNoAssignmentIsOmitted() {
        let lines = fixture().lines()
        XCTAssertFalse(lines.contains { $0.hasPrefix("ws3 ") })
        XCTAssertEqual(lines.filter { $0.hasPrefix("ws") }.count, 3)
    }

    func testEmptyStateStillReportsScratchpadAndTotals() {
        let empty = StateDumpFormatter(
            screens: [], homeScreenNames: [:], visibleWorkspaces: [],
            assignments: [:], hidden: [], reserved: [], floating: [],
            trees: [:], scratchpad: [], knownCount: 0
        )
        XCTAssertEqual(empty.lines(), [
            "scratchpad=[]",
            "minima=[]",
            "recovery pending=[] unverified=[]",
            "known=0 hidden=0 reserved=0 floating=0"
        ])
    }

    func testMissingHomeScreenFallsBackToQuestionMark() {
        let orphan = StateDumpFormatter(
            screens: [], homeScreenNames: [:], visibleWorkspaces: [],
            assignments: [7: 5], hidden: [], reserved: [], floating: [],
            trees: [:], scratchpad: [], knownCount: 1
        )
        XCTAssertEqual(orphan.lines().first,
                       "ws5 home=? visible=false assigned=[7] hidden=[] reserved=[] floating=[] tree(?)=[]")
    }

    func testMinimaAreSortedByIdAndRecoveryStateIsReported() {
        var formatter = StateDumpFormatter(
            screens: [], homeScreenNames: [:], visibleWorkspaces: [],
            assignments: [:], hidden: [], reserved: [], floating: [],
            trees: [:], scratchpad: [], knownCount: 3,
            minima: [77: CGSize(width: 1496, height: 841.5),
                     12: CGSize(width: 0, height: 360)]
        )
        formatter.pendingRecovery = [77, 12]
        formatter.unverifiedGeometry = [12]

        XCTAssertEqual(formatter.lines(), [
            "scratchpad=[]",
            "minima=[12:0x360, 77:1496x841.5]",
            "recovery pending=[12, 77] unverified=[12]",
            "known=3 hidden=0 reserved=0 floating=0"
        ])
    }
}
