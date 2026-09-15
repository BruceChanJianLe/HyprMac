import XCTest
@testable import HyprMac

final class WelcomeContentTests: XCTestCase {
    func testTutorialChordUsesConfiguredHyprKeyAndSavedBinding() {
        let binds = [Keybind(
            keyCode: 40,
            modifiers: [.hypr, .control, .shift],
            action: .toggleFloating)]

        let chord = WelcomeContent.chord(in: binds, hyprKey: .f15) {
            if case .toggleFloating = $0 { return true }
            return false
        }

        XCTAssertEqual(chord, "F15 ⌃ ⇧ K")
    }

    func testTutorialChordReturnsNilWhenActionWasRemoved() {
        XCTAssertNil(WelcomeContent.chord(in: [], hyprKey: .capsLock) { _ in true })
    }
}
