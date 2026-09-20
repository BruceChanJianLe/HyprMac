import XCTest
@testable import HyprMac

// WindowRuleTests cover per-app workspace pins: the placement decision
// itself (ActionDispatcher.pinnedWorkspace) and the wire format that
// carries the rules between builds through config.json.
//
// the decision is a static over plain values, so no AX, no live screens,
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

    // MARK: - wire format

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
