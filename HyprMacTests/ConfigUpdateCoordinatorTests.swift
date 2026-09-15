import XCTest
import Combine
@testable import HyprMac

final class ConfigUpdateCoordinatorTests: XCTestCase {
    private func requireIsolatedHome() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HYPRMAC_HEADLESS_TESTS"] == "1",
              let fixedHome = environment["CFFIXED_USER_HOME"] else {
            throw XCTSkip("UserConfig mutation tests require the isolated test home")
        }
        let homePath = URL(fileURLWithPath: fixedHome).standardizedFileURL.path
        let configPath = ConfigStore.configPath.standardizedFileURL.path
        guard configPath.hasPrefix(homePath + "/") else {
            throw XCTSkip("ConfigStore is not rooted under the isolated test home")
        }
    }

    private func restore(_ data: Data?, to url: URL) {
        if let data {
            try? data.write(to: url)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func state(
        gap: CGFloat = 8,
        padding: CGFloat = 8,
        splits: [String: Int] = [:],
        disabled: Set<String> = [],
        showBorder: Bool = true,
        focusColor: String? = nil,
        floatingColor: String? = nil,
        bracketStyle: FocusBracketStyle = .rounded,
        bracketColor: String? = nil,
        bracketRadius: CGFloat = 14,
        dim: Bool = false,
        intensity: Double = 0.2,
        fade: Double = 0.22,
        radius: CGFloat = 10
    ) -> RuntimeConfigState {
        RuntimeConfigState(
            enabled: true, keybinds: [], hyprKey: .capsLock,
            gapSize: gap, outerPadding: padding,
            maxSplitsPerMonitor: splits, disabledMonitors: disabled,
            showFocusBorder: showBorder, focusBorderColorHex: focusColor,
            floatingBorderColorHex: floatingColor,
            focusBracketStyle: bracketStyle, focusBracketColorHex: bracketColor,
            focusBracketRadius: bracketRadius,
            dimInactiveWindows: dim, dimIntensity: intensity,
            chromeFadeDurationSec: fade, windowCornerRadius: radius,
            scratchpadTileByDefault: true, scratchpadRegionInset: 0.06)
    }

    func testUnchangedReloadHasNoRuntimeEffects() {
        let original = state()
        let coordinator = ConfigUpdateCoordinator(initial: original)
        var effects = 0
        coordinator.onEnabled = { _ in effects += 1 }
        coordinator.onKeybinds = { _ in effects += 1 }
        coordinator.onHyprKey = { _ in effects += 1 }
        coordinator.onLayoutGeometry = { _, _ in effects += 1 }
        coordinator.onMaximumSplits = { _ in effects += 1 }
        coordinator.onDisabledMonitors = { _ in effects += 1 }
        coordinator.onChrome = { _, _ in effects += 1 }
        coordinator.onScratchpadRegion = { _ in effects += 1 }
        coordinator.onScratchpadEntryMode = { _ in effects += 1 }

        coordinator.receive(original)

        XCTAssertEqual(effects, 0)
    }

    func testEveryVisualChangeUsesOnlyChromeRoute() {
        let original = state()
        let variants = [
            state(showBorder: false),
            state(focusColor: "112233"),
            state(floatingColor: "445566"),
            state(bracketStyle: .off),
            state(bracketColor: "778899"),
            state(bracketRadius: 9),
            state(dim: true),
            state(intensity: 0.4),
            state(fade: 0.5),
            state(radius: 18),
        ]

        for variant in variants {
            let coordinator = ConfigUpdateCoordinator(initial: original)
            var chrome = 0
            var layout = 0
            var topology = 0
            var workspace = 0
            var focus = 0
            coordinator.onChrome = { state, _ in
                chrome += 1
                XCTAssertEqual(state, variant, "chrome receives current post-change state")
            }
            coordinator.onLayoutGeometry = { _, _ in layout += 1 }
            coordinator.onMaximumSplits = { _ in topology += 1 }
            coordinator.onDisabledMonitors = { _ in workspace += 1 }
            coordinator.onEnabled = { _ in focus += 1 }

            coordinator.receive(variant)

            XCTAssertEqual(chrome, 1)
            XCTAssertEqual(layout, 0)
            XCTAssertEqual(topology, 0)
            XCTAssertEqual(workspace, 0)
            XCTAssertEqual(focus, 0)
        }
    }

    func testGeometryAndTopologyChangesReachTheirProductionRoutes() {
        let original = state()
        let coordinator = ConfigUpdateCoordinator(initial: original)
        var layouts: [(CGFloat, CGFloat)] = []
        var splitUpdates: [[String: Int]] = []
        var monitorUpdates: [Set<String>] = []
        coordinator.onLayoutGeometry = { layouts.append(($0, $1)) }
        coordinator.onMaximumSplits = { splitUpdates.append($0) }
        coordinator.onDisabledMonitors = { monitorUpdates.append($0) }

        coordinator.receive(state(gap: 12, padding: 14))
        coordinator.receive(state(gap: 12, padding: 14, splits: ["Main": 4]))
        coordinator.receive(state(
            gap: 12, padding: 14, splits: ["Main": 4], disabled: ["Side"]))

        XCTAssertEqual(layouts.count, 1)
        XCTAssertEqual(layouts[0].0, 12)
        XCTAssertEqual(layouts[0].1, 14)
        XCTAssertEqual(splitUpdates, [["Main": 4]])
        XCTAssertEqual(monitorUpdates, [["Side"]])
    }

    func testRepeatedUnchangedSnapshotsDoNotMultiplyNextUpdate() {
        let original = state()
        let coordinator = ConfigUpdateCoordinator(initial: original)
        var layoutCount = 0
        coordinator.onLayoutGeometry = { _, _ in layoutCount += 1 }

        coordinator.receive(original)
        coordinator.receive(original)
        coordinator.receive(state(gap: 10))

        XCTAssertEqual(layoutCount, 1)
    }

    func testMultiFieldVisualUpdateReportsExactChromeFlagsOnce() {
        let original = state()
        let coordinator = ConfigUpdateCoordinator(initial: original)
        var received: [ChromeConfigChanges] = []
        coordinator.onChrome = { _, changes in received.append(changes) }

        coordinator.receive(state(
            showBorder: false, focusColor: "112233", bracketStyle: .off,
            dim: true, intensity: 0.4, fade: 0.5, radius: 18))

        XCTAssertEqual(received, [[
            .visibility, .colors, .bracketAppearance, .dimming,
            .fadeDuration, .windowCornerRadius,
        ]])
    }

    func testEnabledKeybindHyprAndScratchpadRoutesHavePositiveCoverage() {
        let original = state()
        let coordinator = ConfigUpdateCoordinator(initial: original)
        var enabled = 0
        var keybinds = 0
        var keys = 0
        var regions = 0
        var modes = 0
        coordinator.onEnabled = { _ in enabled += 1 }
        coordinator.onKeybinds = { _ in keybinds += 1 }
        coordinator.onHyprKey = { _ in keys += 1 }
        coordinator.onScratchpadRegion = { _ in regions += 1 }
        coordinator.onScratchpadEntryMode = { _ in modes += 1 }

        coordinator.receive(RuntimeConfigState(
            enabled: false,
            keybinds: [Keybind(keyCode: 18, modifiers: .hypr, action: .switchWorkspace(1))],
            hyprKey: .tab, gapSize: 8, outerPadding: 8,
            maxSplitsPerMonitor: [:], disabledMonitors: [],
            showFocusBorder: true, focusBorderColorHex: nil, floatingBorderColorHex: nil,
            focusBracketStyle: .rounded, focusBracketColorHex: nil,
            focusBracketRadius: 14,
            dimInactiveWindows: false, dimIntensity: 0.2,
            chromeFadeDurationSec: 0.22, windowCornerRadius: 10,
            scratchpadTileByDefault: false, scratchpadRegionInset: 0.1))

        XCTAssertEqual([enabled, keybinds, keys, regions, modes], [1, 1, 1, 1, 1])
    }

    func testProductionObservationIsInstalledOnlyOnceAndReadsStoredValue() throws {
        try requireIsolatedHome()
        let configBefore = try? Data(contentsOf: ConfigStore.configPath)
        let monitorBefore = try? Data(contentsOf: ConfigStore.monitorConfigPath)
        defer {
            restore(configBefore, to: ConfigStore.configPath)
            restore(monitorBefore, to: ConfigStore.monitorConfigPath)
        }
        let config = UserConfig()
        let coordinator = ConfigUpdateCoordinator(initial: RuntimeConfigState(config))
        var receivedGaps: [CGFloat] = []
        coordinator.onLayoutGeometry = { gap, _ in receivedGaps.append(gap) }

        coordinator.observe(config)
        coordinator.observe(config)
        config.gapSize += 2

        XCTAssertEqual(receivedGaps, [config.gapSize])
    }

    func testVisualSaveAndUnchangedReloadStayOffLayoutRoutes() throws {
        try requireIsolatedHome()
        let configBefore = try? Data(contentsOf: ConfigStore.configPath)
        let monitorBefore = try? Data(contentsOf: ConfigStore.monitorConfigPath)
        defer {
            restore(configBefore, to: ConfigStore.configPath)
            restore(monitorBefore, to: ConfigStore.monitorConfigPath)
        }
        let config = UserConfig()
        let coordinator = ConfigUpdateCoordinator(initial: RuntimeConfigState(config))
        var chromeStates: [RuntimeConfigState] = []
        var layouts = 0
        var topology = 0
        var workspaces = 0
        coordinator.onChrome = { state, _ in chromeStates.append(state) }
        coordinator.onLayoutGeometry = { _, _ in layouts += 1 }
        coordinator.onMaximumSplits = { _ in topology += 1 }
        coordinator.onDisabledMonitors = { _ in workspaces += 1 }
        coordinator.observe(config)

        config.focusBorderColorHex = "123456"
        config.reloadFromDisk()

        XCTAssertEqual(chromeStates.count, 1)
        XCTAssertEqual(chromeStates.first?.focusBorderColorHex, "123456")
        XCTAssertEqual(layouts, 0)
        XCTAssertEqual(topology, 0)
        XCTAssertEqual(workspaces, 0)
    }

    func testStoppedManagerCannotShowBracketsForAnAppearanceChange() {
        XCTAssertFalse(FocusBracketAppearanceUpdate.shouldShow(
            isRunning: false, hyprHeld: true, style: .rounded, isVisible: false))
    }

    func testTurningBracketsOnWhileHyprHeldRequestsOneVisualShow() {
        XCTAssertTrue(FocusBracketAppearanceUpdate.shouldShow(
            isRunning: true, hyprHeld: true, style: .rounded, isVisible: false))
        XCTAssertFalse(FocusBracketAppearanceUpdate.shouldShow(
            isRunning: true, hyprHeld: false, style: .rounded, isVisible: false))
        XCTAssertFalse(FocusBracketAppearanceUpdate.shouldShow(
            isRunning: true, hyprHeld: true, style: .off, isVisible: false))
        XCTAssertFalse(FocusBracketAppearanceUpdate.shouldShow(
            isRunning: true, hyprHeld: true, style: .rounded, isVisible: true))
    }

    func testWindowAndBracketRadiiHaveIndependentChromeEffects() {
        let original = state()
        let windowCoordinator = ConfigUpdateCoordinator(initial: original)
        let bracketCoordinator = ConfigUpdateCoordinator(initial: original)
        var windowEffects: ChromeConfigChanges = []
        var bracketEffects: ChromeConfigChanges = []
        var statefulRoutes = 0
        windowCoordinator.onChrome = { _, effects in windowEffects = effects }
        bracketCoordinator.onChrome = { _, effects in bracketEffects = effects }
        for coordinator in [windowCoordinator, bracketCoordinator] {
            coordinator.onLayoutGeometry = { _, _ in statefulRoutes += 1 }
            coordinator.onMaximumSplits = { _ in statefulRoutes += 1 }
            coordinator.onDisabledMonitors = { _ in statefulRoutes += 1 }
        }

        windowCoordinator.receive(state(radius: 18))
        bracketCoordinator.receive(state(bracketRadius: 9))

        XCTAssertEqual(windowEffects, [.windowCornerRadius])
        XCTAssertEqual(bracketEffects, [.bracketAppearance])
        XCTAssertEqual(statefulRoutes, 0)
    }

    func testDiskReloadAppliesHoverRateBeforeItsSingleRuntimeSignal() throws {
        try requireIsolatedHome()
        let configBefore = try? Data(contentsOf: ConfigStore.configPath)
        let monitorBefore = try? Data(contentsOf: ConfigStore.monitorConfigPath)
        defer {
            restore(configBefore, to: ConfigStore.configPath)
            restore(monitorBefore, to: ConfigStore.monitorConfigPath)
        }
        let config = UserConfig()
        config.mouseHoverPollHz = 47
        let savedAt47 = try Data(contentsOf: ConfigStore.configPath)
        config.mouseHoverPollHz = 88

        var observed: [Int] = []
        let observation = config.didApplyRuntimeChange.sink {
            observed.append(config.mouseHoverPollHz)
        }
        defer { observation.cancel() }

        try savedAt47.write(to: ConfigStore.configPath)
        config.reloadFromDisk()

        XCTAssertEqual(config.mouseHoverPollHz, 47)
        XCTAssertEqual(observed, [47])
    }
}
