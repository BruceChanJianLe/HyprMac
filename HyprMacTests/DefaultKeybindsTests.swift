import XCTest
@testable import HyprMac
import Carbon

// DefaultKeybindsTests verify the shipped default keybind table.
// these are cheap structural invariants — we don't simulate hotkey
// dispatch, just confirm the table is internally consistent.

final class DefaultKeybindsTests: XCTestCase {

    func testToggleFloatDefaultAndDisplaysOmitShift() throws {
        let binds = Keybind.defaults.filter { $0.action == .toggleFloating }
        XCTAssertEqual(binds.count, 1)
        let bind = try XCTUnwrap(binds.first)
        XCTAssertEqual(bind.keyCode, UInt16(kVK_ANSI_T))
        XCTAssertEqual(bind.modifiers, .hypr)
        XCTAssertFalse(bind.modifiers.contains(.shift))
        XCTAssertEqual(bind.displayString, "HYPR+T")
        XCTAssertEqual(bind.badgeLabels(hyprLabel: "⇪"), ["⇪", "T"])
        XCTAssertEqual(bind.overlayChord, "HYPR T")
        XCTAssertEqual(Keybind.defaults.filter { $0.id == bind.id }, [bind])
    }

    func testShiftSelectsFloatingCycleInsteadOfToggle() {
        let manager = HotkeyManager()
        manager.updateKeybinds(Keybind.defaults)
        let dispatched = expectation(description: "floating shortcuts dispatched")
        dispatched.expectedFulfillmentCount = 2
        var actions: [Action] = []
        manager.onAction = { actions.append($0); dispatched.fulfill() }
        let hypr = CGEvent(keyboardEventSource: nil,
                           virtualKey: CGKeyCode(HyprKey.capsLock.keyCode), keyDown: true)!
        XCTAssertNil(manager.handleEvent(.keyDown, hypr))
        let shifted = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_T), keyDown: true)!
        shifted.flags = .maskShift
        XCTAssertNil(manager.handleEvent(.keyDown, shifted))
        let plain = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_T), keyDown: true)!
        plain.flags = []
        XCTAssertNil(manager.handleEvent(.keyDown, plain))
        wait(for: [dispatched], timeout: 1)
        XCTAssertEqual(actions, [.focusFloating, .toggleFloating])
    }

    func testEmptyWorkspaceAndFloatingFocusDefaults() throws {
        let empty = try XCTUnwrap(Keybind.defaults.first {
            $0.action == .moveToNextEmptyWorkspace
        })
        XCTAssertEqual(empty.keyCode, UInt16(kVK_ANSI_F))
        XCTAssertEqual(empty.modifiers, .hypr)
        XCTAssertEqual(empty.displayString, "HYPR+F")
        XCTAssertEqual(empty.actionDescription, "Move to dedicated workspace")
        XCTAssertEqual(KeybindCategory.from(empty.action), .workspaces)
        XCTAssertFalse(empty.touchesFloatingLayer)

        let floating = try XCTUnwrap(Keybind.defaults.first { $0.action == .focusFloating })
        XCTAssertEqual(floating.keyCode, UInt16(kVK_ANSI_T))
        XCTAssertEqual(floating.modifiers, [.hypr, .shift])
        XCTAssertEqual(floating.displayString, "HYPR+⇧+T")
    }

    func testEmptyWorkspaceAndFloatingFocusDispatchOnDistinctChords() {
        let manager = HotkeyManager()
        manager.updateKeybinds(Keybind.defaults)
        let dispatched = expectation(description: "both repurposed chords dispatch")
        dispatched.expectedFulfillmentCount = 2
        var actions: [Action] = []
        manager.onAction = { actions.append($0); dispatched.fulfill() }

        let hypr = CGEvent(keyboardEventSource: nil,
                           virtualKey: CGKeyCode(HyprKey.capsLock.keyCode), keyDown: true)!
        XCTAssertNil(manager.handleEvent(.keyDown, hypr))
        let empty = CGEvent(keyboardEventSource: nil,
                            virtualKey: CGKeyCode(kVK_ANSI_F), keyDown: true)!
        XCTAssertNil(manager.handleEvent(.keyDown, empty))
        let floating = CGEvent(keyboardEventSource: nil,
                               virtualKey: CGKeyCode(kVK_ANSI_T), keyDown: true)!
        floating.flags = .maskShift
        XCTAssertNil(manager.handleEvent(.keyDown, floating))

        wait(for: [dispatched], timeout: 1)
        XCTAssertEqual(actions, [.moveToNextEmptyWorkspace, .focusFloating])
    }

    func testBadgeFormatterPreservesModifierOrder() {
        let bind = Keybind(keyCode: UInt16(kVK_ANSI_T),
                          modifiers: [.hypr, .control, .option, .shift, .command], action: .toggleFloating)
        XCTAssertEqual(bind.badgeLabels(), ["HYPR", "⌃", "⌥", "⇧", "⌘", "T"])
        XCTAssertEqual(bind.overlayChord, "HYPR ⌃ ⌥ ⇧ ⌘ T")
    }

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
        // Hypr+1..0 → switchWorkspace(1...10), shifted → moveToWorkspace(1...10).
        var switchN: Set<Int> = []
        var moveN: Set<Int> = []
        for kb in Keybind.defaults {
            switch kb.action {
            case .switchWorkspace(let n): switchN.insert(n)
            case .moveToWorkspace(let n): moveN.insert(n)
            default: break
            }
        }
        XCTAssertEqual(switchN, Set(1...10))
        XCTAssertEqual(moveN, Set(1...10))
        XCTAssertTrue(Keybind.defaults.contains {
            $0.keyCode == UInt16(kVK_ANSI_0) && $0.modifiers == .hypr
                && $0.action == .switchWorkspace(10)
        })
        XCTAssertTrue(Keybind.defaults.contains {
            $0.keyCode == UInt16(kVK_ANSI_0) && $0.modifiers == [.hypr, .shift]
                && $0.action == .moveToWorkspace(10)
        })
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

    func testApplyWorkspacePinsUsesHyprShiftR() throws {
        let bind = try XCTUnwrap(Keybind.defaults.first { $0.action == .applyWindowRules })
        XCTAssertEqual(bind.keyCode, UInt16(kVK_ANSI_R))
        XCTAssertEqual(bind.modifiers, [.hypr, .shift])
        XCTAssertEqual(bind.actionDescription, "Apply Workspace Pins")
        XCTAssertEqual(KeybindCategory.from(.applyWindowRules), .workspaces)
    }

    // a bulk move must not repeat while the chord is held, and it needs a
    // running engine to move anything
    func testApplyWorkspacePinsIgnoresKeyRepeatAndNeedsTiling() {
        XCTAssertTrue(HotkeyManager.shouldDispatchAction(
            .applyWindowRules, tilingEnabled: true, isRepeat: false))
        XCTAssertFalse(HotkeyManager.shouldDispatchAction(
            .applyWindowRules, tilingEnabled: true, isRepeat: true))
        XCTAssertFalse(HotkeyManager.actionIsAvailable(.applyWindowRules, tilingEnabled: false))
    }

    func testMonitorMoveBindsAllFourArrowsUnderHyprCtrl() throws {
        let expected: [(Direction, Int)] = [
            (.left, kVK_LeftArrow), (.right, kVK_RightArrow), (.up, kVK_UpArrow), (.down, kVK_DownArrow)
        ]
        for (direction, key) in expected {
            let bind = try XCTUnwrap(Keybind.defaults.first { $0.action == .moveWindowToMonitor(direction) },
                                     "no default for \(direction)")
            XCTAssertEqual(bind.keyCode, UInt16(key))
            XCTAssertEqual(bind.modifiers, [.hypr, .control])
        }
        XCTAssertEqual(Keybind(keyCode: 0, modifiers: .hypr, action: .moveWindowToMonitor(.up)).actionDescription,
                       "Move Window to Upper Monitor")
        XCTAssertEqual(Keybind(keyCode: 0, modifiers: .hypr, action: .moveWindowToMonitor(.down)).actionDescription,
                       "Move Window to Lower Monitor")
    }

    func testWorkspaceOverviewUsesHyprO() throws {
        let bind = try XCTUnwrap(Keybind.defaults.first { $0.action == .showWorkspaceOverview })
        XCTAssertEqual(bind.keyCode, UInt16(kVK_ANSI_O))
        XCTAssertEqual(bind.modifiers, .hypr)
        XCTAssertEqual(bind.actionDescription, "Show Workspace Overview")
    }

    func testPauseResumeRemainsAvailableWhileTilingIsDisabled() {
        XCTAssertTrue(HotkeyManager.actionIsAvailable(.toggleTiling, tilingEnabled: false))
        XCTAssertTrue(HotkeyManager.actionIsAvailable(.showKeybinds, tilingEnabled: false))
        XCTAssertTrue(HotkeyManager.actionIsAvailable(.showWorkspaceOverview, tilingEnabled: false))
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
        XCTAssertTrue(HotkeyManager.shouldDispatchAction(
            .moveToNextEmptyWorkspace, tilingEnabled: true, isRepeat: false))
        XCTAssertFalse(HotkeyManager.shouldDispatchAction(
            .moveToNextEmptyWorkspace, tilingEnabled: true, isRepeat: true))
        XCTAssertFalse(HotkeyManager.shouldDispatchAction(
            .moveToNextEmptyWorkspace, tilingEnabled: false, isRepeat: false))
    }

    func testRunCommandIgnoresKeyRepeatAndFollowsTilingAvailability() {
        let run = Action.runCommand(label: "x", command: "/usr/bin/true")
        XCTAssertFalse(HotkeyManager.shouldDispatchAction(
            run, tilingEnabled: true, isRepeat: true))
        XCTAssertTrue(HotkeyManager.shouldDispatchAction(
            run, tilingEnabled: true, isRepeat: false))
        // same rule as launchApp: paused tiling parks it too
        XCTAssertFalse(HotkeyManager.actionIsAvailable(run, tilingEnabled: false))
        XCTAssertTrue(HotkeyManager.ignoresAutorepeat(run))
        XCTAssertFalse(HotkeyManager.ignoresAutorepeat(.closeWindow))
    }

    func testRunCommandCaseTagCarriesNoCommandText() {
        let tag = ActionDispatcher.discriminator(
            for: .runCommand(label: "Secret", command: "/usr/bin/true --token abc"))
        XCTAssertEqual(tag, "runCommand")
        XCTAssertFalse(tag.contains("abc"))
        XCTAssertFalse(tag.contains("Secret"))
    }

    func testNoDefaultKeybindRunsACommand() {
        XCTAssertFalse(Keybind.defaults.contains { if case .runCommand = $0.action { return true }; return false })
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
        let emptyWorkspace = CGEvent(
            keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_F), keyDown: true)!
        XCTAssertNotNil(manager.handleEvent(.keyDown, emptyWorkspace))

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
