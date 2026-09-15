import XCTest
@testable import HyprMac
import Carbon

final class WelcomeContentTests: XCTestCase {
    func testTutorialRequestUsesInjectedRouteAfterClosingHelp() {
        let overlay = KeybindOverlayController()
        var requests = 0
        overlay.onShowTutorial = { [weak overlay] in
            XCTAssertEqual(overlay?.isShowing, false)
            requests += 1
        }

        overlay.openTutorial()
        overlay.openTutorial()

        XCTAssertEqual(requests, 2)
    }

    func testTutorialChordUsesConfiguredHyprKeyAndSavedBinding() {
        let binds = [Keybind(
            keyCode: 40,
            modifiers: [.hypr, .control, .shift],
            action: .toggleFloating)]

        let chord = WelcomeContent.chord(in: binds, hyprKey: .f15) {
            if case .toggleFloating = $0 { return true }
            return false
        }

        XCTAssertEqual(chord, "HYPR ⌃ ⇧ K")
    }

    func testTutorialChordReturnsNilWhenActionWasRemoved() {
        XCTAssertNil(WelcomeContent.chord(in: [], hyprKey: .capsLock) { _ in true })
    }

    func testOverlayGroupsOnlyCanonicalWorkspaceNumberKeys() {
        let canonical = Keybind(
            keyCode: UInt16(kVK_ANSI_3), modifiers: .hypr,
            action: .switchWorkspace(3))
        let customized = Keybind(
            keyCode: UInt16(kVK_ANSI_Q), modifiers: .hypr,
            action: .switchWorkspace(3))

        XCTAssertTrue(KeybindOverlayGrouping.usesCanonicalWorkspaceKey(canonical, number: 3))
        XCTAssertFalse(KeybindOverlayGrouping.usesCanonicalWorkspaceKey(customized, number: 3))
    }

    func testOverlayGroupsOnlyMatchingArrowKeys() {
        let canonical = Keybind(
            keyCode: UInt16(kVK_LeftArrow), modifiers: .hypr,
            action: .focusDirection(.left))
        let customized = Keybind(
            keyCode: UInt16(kVK_ANSI_H), modifiers: .hypr,
            action: .focusDirection(.left))

        XCTAssertTrue(KeybindOverlayGrouping.usesCanonicalDirectionKey(canonical, direction: .left))
        XCTAssertFalse(KeybindOverlayGrouping.usesCanonicalDirectionKey(customized, direction: .left))
    }

    func testOverlaySummarizesOnlyTheCompleteWorkspaceRange() {
        XCTAssertTrue(KeybindOverlayGrouping.isCompleteWorkspaceRange(Array(1...9)))
        XCTAssertFalse(KeybindOverlayGrouping.isCompleteWorkspaceRange(Array(1...8)))
        XCTAssertFalse(KeybindOverlayGrouping.isCompleteWorkspaceRange([1, 3]))
        XCTAssertFalse(KeybindOverlayGrouping.isCompleteWorkspaceRange([1, 1]))
    }
}
