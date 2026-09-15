import XCTest
@testable import HyprMac
import Carbon

// DefaultKeybindsTests verify the shipped default keybind table.
// these are cheap structural invariants — we don't simulate hotkey
// dispatch, just confirm the table is internally consistent.

final class DefaultKeybindsTests: XCTestCase {

    func testEveryDefaultRoundTripsThroughCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for kb in Keybind.defaults {
            let data = try encoder.encode(kb)
            let decoded = try decoder.decode(Keybind.self, from: data)
            XCTAssertEqual(decoded.action, kb.action,
                           "default keybind action did not round-trip: \(kb)")
            XCTAssertEqual(decoded.keyCode, kb.keyCode)
            XCTAssertEqual(decoded.modifiers, kb.modifiers)
        }
    }

    func testEveryDefaultUsesUniqueChord() {
        var seen: Set<String> = []
        for kb in Keybind.defaults {
            let chord = "\(kb.modifiers.rawValue)-\(kb.keyCode)"
            XCTAssertFalse(seen.contains(chord),
                           "duplicate default chord \(chord) on action \(kb.action)")
            seen.insert(chord)
        }
    }

    func testDefaultsCoverEachWorkspaceNumber() {
        // Hypr+1..9 → switchWorkspace(N), Hypr+Shift+1..9 → moveToWorkspace(N).
        var switchN: Set<Int> = []
        var moveN: Set<Int> = []
        for kb in Keybind.defaults {
            switch kb.action {
            case .switchWorkspace(let n): switchN.insert(n)
            case .moveToWorkspace(let n): moveN.insert(n)
            default: break
            }
        }
        XCTAssertEqual(switchN, Set(1...9))
        XCTAssertEqual(moveN, Set(1...9))
    }

    func testDefaultsContainAllDirectionsForFocusAndSwap() {
        var focusDirs: Set<Direction> = []
        var swapDirs: Set<Direction> = []
        for kb in Keybind.defaults {
            switch kb.action {
            case .focusDirection(let d): focusDirs.insert(d)
            case .swapDirection(let d): swapDirs.insert(d)
            default: break
            }
        }
        XCTAssertEqual(focusDirs, Set([.left, .right, .up, .down]))
        XCTAssertEqual(swapDirs, Set([.left, .right, .up, .down]))
    }

    func testDefaultsAreNonEmpty() {
        XCTAssertFalse(Keybind.defaults.isEmpty)
    }

    func testPauseResumeUsesHyprP() throws {
        let bind = try XCTUnwrap(Keybind.defaults.first { $0.action == .toggleTiling })
        XCTAssertEqual(bind.keyCode, UInt16(kVK_ANSI_P))
        XCTAssertEqual(bind.modifiers, .hypr)
    }

    func testPauseResumeRemainsAvailableWhileTilingIsDisabled() {
        XCTAssertTrue(HotkeyManager.actionIsAvailable(.toggleTiling, tilingEnabled: false))
        XCTAssertTrue(HotkeyManager.actionIsAvailable(.showKeybinds, tilingEnabled: false))
        XCTAssertFalse(HotkeyManager.actionIsAvailable(.closeWindow, tilingEnabled: false))
        XCTAssertTrue(HotkeyManager.actionIsAvailable(.showKeybinds, tilingEnabled: true))
    }

    func testPauseResumeIgnoresKeyRepeat() {
        XCTAssertTrue(HotkeyManager.shouldDispatchAction(
            .toggleTiling, tilingEnabled: true, isRepeat: false))
        XCTAssertFalse(HotkeyManager.shouldDispatchAction(
            .toggleTiling, tilingEnabled: true, isRepeat: true))
        XCTAssertTrue(HotkeyManager.shouldDispatchAction(
            .showKeybinds, tilingEnabled: false, isRepeat: true))
    }

    func testPausedEventPathPassesOrdinaryChordAndDispatchesPauseAndHelp() {
        let manager = HotkeyManager()
        manager.updateKeybinds(Keybind.defaults)
        manager.updateTilingEnabled(false)
        let dispatched = expectation(description: "pause and help dispatched")
        dispatched.expectedFulfillmentCount = 2
        var actions: [Action] = []
        manager.onAction = { action in
            actions.append(action)
            dispatched.fulfill()
        }

        let hyprDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(HyprKey.capsLock.keyCode),
            keyDown: true)!
        XCTAssertNil(manager.handleEvent(.keyDown, hyprDown))

        let pause = CGEvent(
            keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_P), keyDown: true)!
        XCTAssertNil(manager.handleEvent(.keyDown, pause))
        let pauseRepeat = CGEvent(
            keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_P), keyDown: true)!
        pauseRepeat.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        XCTAssertNil(manager.handleEvent(.keyDown, pauseRepeat))

        let help = CGEvent(
            keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_K), keyDown: true)!
        XCTAssertNil(manager.handleEvent(.keyDown, help))
        let close = CGEvent(
            keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_W), keyDown: true)!
        XCTAssertNotNil(manager.handleEvent(.keyDown, close))

        wait(for: [dispatched], timeout: 1)
        XCTAssertEqual(actions, [.toggleTiling, .showKeybinds])
    }

    func testPausedHyprReleaseCannotReassertChrome() {
        XCTAssertTrue(WindowManager.permitsHyprReleaseReassert(
            isRunning: true, enabled: true, showFocusBorder: true))
        XCTAssertFalse(WindowManager.permitsHyprReleaseReassert(
            isRunning: false, enabled: true, showFocusBorder: true))
        XCTAssertFalse(WindowManager.permitsHyprReleaseReassert(
            isRunning: true, enabled: false, showFocusBorder: true))
        XCTAssertFalse(WindowManager.permitsHyprReleaseReassert(
            isRunning: true, enabled: true, showFocusBorder: false))
    }

    func testDefaultMergePreservesCustomPauseBinding() {
        let custom = Keybind(
            keyCode: UInt16(kVK_ANSI_U), modifiers: [.hypr, .shift],
            action: .toggleTiling)

        let merged = UserConfig.mergeNewDefaults(saved: [custom])

        XCTAssertEqual(merged.filter { $0.action == .toggleTiling }, [custom])
    }

    func testDefaultMergeDoesNotShadowOccupiedHyprP() {
        let custom = Keybind(
            keyCode: UInt16(kVK_ANSI_P), modifiers: .hypr,
            action: .showKeybinds)

        let merged = UserConfig.mergeNewDefaults(saved: [custom])

        XCTAssertEqual(merged.filter {
            $0.keyCode == UInt16(kVK_ANSI_P) && $0.modifiers == .hypr
        }, [custom])
        XCTAssertFalse(merged.contains { $0.action == .toggleTiling })
    }
}
