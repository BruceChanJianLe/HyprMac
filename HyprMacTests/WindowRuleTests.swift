import XCTest
@testable import HyprMac

// WindowRuleTests cover per-app workspace pins: the placement decision
// itself (ActionDispatcher.pinnedWorkspace), the plan behind the manual
// "apply pins" pass (ActionDispatcher.windowRuleMoves), the startup batches
// that seat pinned windows first, and the wire format that carries rules
// and the action between builds through config.json.
//
// every decision is a static over plain values, so no AX, no live screens,
// and no dispatcher instance are involved.

final class WindowRuleTests: XCTestCase {

    private let everyWorkspaceEligible: (Int) -> Bool = { _ in true }

    private func rules(_ pairs: (String, Int)...) -> [WindowRule] {
        pairs.map { WindowRule(bundleID: $0.0, workspace: $0.1) }
    }

    // MARK: - the placement decision

    func testMatchingBundleIDPinsToItsWorkspace() {
        XCTAssertEqual(
            ActionDispatcher.pinnedWorkspace(
                forBundleID: "com.spotify.client",
                rules: rules(("com.spotify.client", 9)),
                isEligible: everyWorkspaceEligible),
            9)
    }

    func testUnclaimedAppFallsThroughToScreenPlacement() {
        XCTAssertNil(
            ActionDispatcher.pinnedWorkspace(
                forBundleID: "com.apple.Safari",
                rules: rules(("com.spotify.client", 9)),
                isEligible: everyWorkspaceEligible))
    }

    func testNoRulesPinsNothing() {
        XCTAssertNil(
            ActionDispatcher.pinnedWorkspace(
                forBundleID: "com.spotify.client", rules: [],
                isEligible: everyWorkspaceEligible))
    }

    // discovery cannot always name the owning app - a window whose bundle id
    // is still nil must place normally rather than matching some rule by luck
    func testUnknownBundleIDPinsNothing() {
        XCTAssertNil(
            ActionDispatcher.pinnedWorkspace(
                forBundleID: nil,
                rules: rules(("com.spotify.client", 9)),
                isEligible: everyWorkspaceEligible))
    }

    // a hand-edited config can name a workspace that does not exist
    func testWorkspaceOutOfRangeIsIgnored() {
        for workspace in [0, -1, 11, 99] {
            XCTAssertNil(
                ActionDispatcher.pinnedWorkspace(
                    forBundleID: "com.spotify.client",
                    rules: rules(("com.spotify.client", workspace)),
                    isEligible: everyWorkspaceEligible),
                "workspace \(workspace) should not pin")
        }
    }

    func testWorkspace10Pins() {
        XCTAssertEqual(
            ActionDispatcher.pinnedWorkspace(
                forBundleID: "com.spotify.client",
                rules: rules(("com.spotify.client", 10)),
                isEligible: everyWorkspaceEligible),
            10)
    }

    // the rule's display may be unplugged or excluded from tiling. placing
    // the window normally beats stranding it where nothing can show it.
    func testIneligibleWorkspaceFallsThroughToScreenPlacement() {
        XCTAssertNil(
            ActionDispatcher.pinnedWorkspace(
                forBundleID: "com.spotify.client",
                rules: rules(("com.spotify.client", 9)),
                isEligible: { _ in false }))
    }

    func testEligibilityIsAskedOnlyAboutTheRulesWorkspace() {
        var asked: [Int] = []
        _ = ActionDispatcher.pinnedWorkspace(
            forBundleID: "com.spotify.client",
            rules: rules(("com.apple.Safari", 3), ("com.spotify.client", 9)),
            isEligible: { asked.append($0); return true })
        XCTAssertEqual(asked, [9])
    }

    // the settings UI keeps one rule per app, but a hand-edited file can
    // hold two. first wins - deterministically, not by dictionary order.
    func testDuplicateBundleIDTakesTheFirstRule() {
        XCTAssertEqual(
            ActionDispatcher.pinnedWorkspace(
                forBundleID: "com.spotify.client",
                rules: rules(("com.spotify.client", 9), ("com.spotify.client", 4)),
                isEligible: everyWorkspaceEligible),
            9)
    }

    // MARK: - the manual pass

    private typealias Candidate = (windowID: CGWindowID, bundleID: String?)

    private func moves(
        _ windows: [Candidate],
        current: [CGWindowID: Int],
        pins: [String: Int],
        assignments: [Int: Set<CGWindowID>] = [:],
        excluded: Set<CGWindowID> = [],
        capacity: Int = 8
    ) -> (moves: [Int: [CGWindowID]], refused: [CGWindowID]) {
        ActionDispatcher.windowRuleMoves(
            windows: windows,
            currentWorkspaceFor: { current[$0] },
            pinnedWorkspaceFor: { $0.flatMap { pins[$0] } },
            existingAssignments: assignments,
            excludedWindowIDs: excluded,
            capacityForWorkspace: { _ in capacity })
    }

    func testPinnedWindowsElsewhereMoveToTheirWorkspace() {
        let plan = moves(
            [(1, "com.spotify.client"), (2, "com.spotify.client"), (3, "com.apple.Safari")],
            current: [1: 2, 2: 5, 3: 2],
            pins: ["com.spotify.client": 9])
        XCTAssertEqual(plan.moves, [9: [1, 2]])
        XCTAssertTrue(plan.refused.isEmpty)
    }

    func testWindowsAlreadyOnTheirWorkspaceStay() {
        let plan = moves(
            [(1, "com.spotify.client"), (2, "com.spotify.client")],
            current: [1: 9, 2: 3],
            pins: ["com.spotify.client": 9])
        XCTAssertEqual(plan.moves, [9: [2]])
    }

    // an untracked window has nothing to move from; a scratchpad member
    // lives on workspace 0 and belongs to that layer, not to any pin
    func testUntrackedAndScratchpadWindowsAreLeftAlone() {
        let plan = moves(
            [(1, "com.spotify.client"), (2, "com.spotify.client")],
            current: [2: ScratchpadController.workspace],
            pins: ["com.spotify.client": 9])
        XCTAssertTrue(plan.moves.isEmpty)
        XCTAssertTrue(plan.refused.isEmpty)
    }

    func testEachAppGoesToItsOwnWorkspace() {
        let plan = moves(
            [(1, "com.spotify.client"), (2, "com.apple.MobileSMS"), (3, nil)],
            current: [1: 1, 2: 1, 3: 1],
            pins: ["com.spotify.client": 9, "com.apple.MobileSMS": 4])
        XCTAssertEqual(plan.moves, [4: [2], 9: [1]])
    }

    // the user named one workspace. a full destination refuses rather than
    // scattering windows onto the next free workspace, as admission would
    // for a window that has to land somewhere
    func testFullDestinationRefusesTheOverflowInsteadOfSpilling() {
        let plan = moves(
            [(1, "com.spotify.client"), (2, "com.spotify.client"), (3, "com.spotify.client")],
            current: [1: 2, 2: 2, 3: 2],
            pins: ["com.spotify.client": 9],
            assignments: [9: [90, 91]],
            capacity: 4)
        XCTAssertEqual(plan.moves, [9: [1, 2]])
        XCTAssertEqual(plan.refused, [3])
    }

    // floaters and hidden windows hold no tile slot, the same accounting
    // admission uses: they neither fill the destination nor get refused
    func testExcludedWindowsNeitherConsumeNorAreRefusedCapacity() {
        let plan = moves(
            [(1, "com.spotify.client"), (2, "com.spotify.client"), (3, "com.spotify.client")],
            current: [1: 2, 2: 2, 3: 2],
            pins: ["com.spotify.client": 9],
            assignments: [9: [90, 91]],
            excluded: [1, 91],
            capacity: 3)
        XCTAssertEqual(plan.moves, [9: [1, 2, 3]], "one tenant floats, so two tiled slots remain")
        XCTAssertTrue(plan.refused.isEmpty)
    }

    func testIneligiblePinMovesNothing() {
        let plan = ActionDispatcher.windowRuleMoves(
            windows: [(1, "com.spotify.client")],
            currentWorkspaceFor: { _ in 2 },
            pinnedWorkspaceFor: { _ in nil },
            existingAssignments: [:],
            excludedWindowIDs: [],
            capacityForWorkspace: { _ in 8 })
        XCTAssertTrue(plan.moves.isEmpty)
    }

    // MARK: - startup placement

    func testStartupSeatsPinnedWindowsBeforeScreenPlacementFillsTheirWorkspace() {
        let pins: [CGWindowID: Int] = [7: 1, 8: 3]
        let split = RetileAllPlanner.pinnedStartupBatches(
            windowIDs: [5, 6, 7, 8],
            pinnedWorkspaceFor: { pins[$0] },
            order: { $0.sorted(by: >) })
        XCTAssertEqual(split.batches.map(\.preferredWorkspace), [1, 3])
        XCTAssertEqual(split.batches.map(\.windowIDs), [[7], [8]])
        XCTAssertEqual(split.unpinned, [5, 6])

        // the screen batch wants workspace 1 too; the pinned batch, listed
        // first, takes the seat and the screen's excess spills onward
        let plan = RetileAllPlanner.admitStartupBatches(
            split.batches + [RetileAllBatch(preferredWorkspace: 1, windowIDs: split.unpinned)],
            workspaceCount: 4,
            reservedAssignments: [:],
            capacityForWorkspace: { $0 == 1 ? 2 : 4 })
        XCTAssertEqual(plan.assignments[1], [7, 5])
        XCTAssertEqual(plan.assignments[2], [6])
        XCTAssertEqual(plan.assignments[3], [8])
        XCTAssertTrue(plan.overflow.isEmpty)
    }

    func testStartupBatchOrderIsAppliedPerPinnedWorkspace() {
        var ordered: [[CGWindowID]] = []
        let split = RetileAllPlanner.pinnedStartupBatches(
            windowIDs: [3, 1, 2],
            pinnedWorkspaceFor: { _ in 9 },
            order: { ordered.append($0); return $0.sorted() })
        XCTAssertEqual(ordered, [[3, 1, 2]])
        XCTAssertEqual(split.batches.map(\.windowIDs), [[1, 2, 3]])
        XCTAssertTrue(split.unpinned.isEmpty)
    }

    // MARK: - wire format

    func testApplyWindowRulesActionRoundTrips() throws {
        let data = try JSONEncoder().encode(Action.applyWindowRules)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"applyWindowRules":{}}"#)
        XCTAssertEqual(try JSONDecoder().decode(Action.self, from: data), .applyWindowRules)
    }

    func testRulesRoundTripThroughSavedConfig() throws {
        let json = """
        {"keybinds":[],"gapSize":8,"outerPadding":8,"enabled":true,
         "windowRules":[{"bundleID":"com.spotify.client","workspace":9}]}
        """
        let saved = try JSONDecoder().decode(SavedConfig.self, from: Data(json.utf8))
        XCTAssertEqual(saved.windowRules, [WindowRule(bundleID: "com.spotify.client", workspace: 9)])

        let reloaded = try JSONDecoder().decode(
            SavedConfig.self, from: try JSONEncoder().encode(saved))
        XCTAssertEqual(reloaded.windowRules, saved.windowRules)
    }

    // every config written before this feature has no such key
    func testConfigWithoutRulesDecodesAsNoRules() throws {
        let json = #"{"keybinds":[],"gapSize":8,"outerPadding":8,"enabled":true}"#
        let saved = try JSONDecoder().decode(SavedConfig.self, from: Data(json.utf8))
        XCTAssertNil(saved.windowRules)
    }

    // same contract as keybinds: one bad element costs that element only,
    // never the rest of the user's settings
    func testMalformedRuleIsSkippedAndTheConfigSurvives() throws {
        let json = """
        {"keybinds":[],"gapSize":22,"outerPadding":8,"enabled":true,
         "windowRules":[
            {"bundleID":"com.busted.app"},
            {"bundleID":"com.spotify.client","workspace":9}
         ]}
        """
        let saved = try JSONDecoder().decode(SavedConfig.self, from: Data(json.utf8))
        XCTAssertEqual(saved.windowRules, [WindowRule(bundleID: "com.spotify.client", workspace: 9)])
        XCTAssertEqual(saved.gapSize, 22)
        XCTAssertEqual(saved.enabled, true)
    }

    func testEveryRuleMalformedKeepsTheOtherFields() throws {
        let json = """
        {"keybinds":[],"gapSize":14,"outerPadding":8,"enabled":true,
         "windowRules":[{"workspace":"nine"}]}
        """
        let saved = try JSONDecoder().decode(SavedConfig.self, from: Data(json.utf8))
        XCTAssertEqual(saved.windowRules, [])
        XCTAssertEqual(saved.gapSize, 14)
    }
}
