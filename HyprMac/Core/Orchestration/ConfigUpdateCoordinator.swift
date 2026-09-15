import Cocoa
import Combine

/// A post-mutation snapshot of the settings that have live runtime effects.
struct RuntimeConfigState: Equatable {
    let enabled: Bool
    let keybinds: [Keybind]
    let hyprKey: HyprKey
    let gapSize: CGFloat
    let outerPadding: CGFloat
    let maxSplitsPerMonitor: [String: Int]
    let disabledMonitors: Set<String>
    let showFocusBorder: Bool
    let focusBorderColorHex: String?
    let floatingBorderColorHex: String?
    let focusBracketStyle: FocusBracketStyle
    let focusBracketColorHex: String?
    let focusBracketRadius: CGFloat
    let focusBracketThickness: CGFloat
    let focusBracketLength: CGFloat
    let dimInactiveWindows: Bool
    let dimIntensity: Double
    let chromeFadeDurationSec: Double
    let windowCornerRadius: CGFloat
    let scratchpadTileByDefault: Bool
    let scratchpadRegionInset: CGFloat

    init(
        enabled: Bool, keybinds: [Keybind], hyprKey: HyprKey,
        gapSize: CGFloat, outerPadding: CGFloat,
        maxSplitsPerMonitor: [String: Int], disabledMonitors: Set<String>,
        showFocusBorder: Bool, focusBorderColorHex: String?, floatingBorderColorHex: String?,
        focusBracketStyle: FocusBracketStyle, focusBracketColorHex: String?,
        focusBracketRadius: CGFloat,
        focusBracketThickness: CGFloat,
        focusBracketLength: CGFloat = UserConfigDefaults.focusBracketLength,
        dimInactiveWindows: Bool, dimIntensity: Double, chromeFadeDurationSec: Double,
        windowCornerRadius: CGFloat, scratchpadTileByDefault: Bool,
        scratchpadRegionInset: CGFloat
    ) {
        self.enabled = enabled
        self.keybinds = keybinds
        self.hyprKey = hyprKey
        self.gapSize = gapSize
        self.outerPadding = outerPadding
        self.maxSplitsPerMonitor = maxSplitsPerMonitor
        self.disabledMonitors = disabledMonitors
        self.showFocusBorder = showFocusBorder
        self.focusBorderColorHex = focusBorderColorHex
        self.floatingBorderColorHex = floatingBorderColorHex
        self.focusBracketStyle = focusBracketStyle
        self.focusBracketColorHex = focusBracketColorHex
        self.focusBracketRadius = focusBracketRadius
        self.focusBracketThickness = focusBracketThickness
        self.focusBracketLength = focusBracketLength
        self.dimInactiveWindows = dimInactiveWindows
        self.dimIntensity = dimIntensity
        self.chromeFadeDurationSec = chromeFadeDurationSec
        self.windowCornerRadius = windowCornerRadius
        self.scratchpadTileByDefault = scratchpadTileByDefault
        self.scratchpadRegionInset = scratchpadRegionInset
    }

    init(_ config: UserConfig) {
        self.init(
            enabled: config.enabled, keybinds: config.keybinds, hyprKey: config.hyprKey,
            gapSize: config.gapSize, outerPadding: config.outerPadding,
            maxSplitsPerMonitor: config.maxSplitsPerMonitor,
            disabledMonitors: config.disabledMonitors,
            showFocusBorder: config.showFocusBorder,
            focusBorderColorHex: config.focusBorderColorHex,
            floatingBorderColorHex: config.floatingBorderColorHex,
            focusBracketStyle: config.focusBracketStyle,
            focusBracketColorHex: config.focusBracketColorHex,
            focusBracketRadius: config.resolvedFocusBracketRadius,
            focusBracketThickness: config.resolvedFocusBracketThickness,
            focusBracketLength: config.resolvedFocusBracketLength,
            dimInactiveWindows: config.dimInactiveWindows,
            dimIntensity: config.dimIntensity,
            chromeFadeDurationSec: config.chromeFadeDurationSec,
            windowCornerRadius: config.windowCornerRadius,
            scratchpadTileByDefault: config.scratchpadTileByDefault,
            scratchpadRegionInset: config.scratchpadRegionInset)
    }
}

struct ChromeConfigChanges: OptionSet, Equatable {
    let rawValue: Int

    static let visibility = Self(rawValue: 1 << 0)
    static let colors = Self(rawValue: 1 << 1)
    static let dimming = Self(rawValue: 1 << 2)
    static let fadeDuration = Self(rawValue: 1 << 3)
    static let windowCornerRadius = Self(rawValue: 1 << 4)
    static let bracketAppearance = Self(rawValue: 1 << 5)
}

enum FocusBracketAppearanceUpdate {
    static func shouldShow(
        isRunning: Bool,
        hyprHeld: Bool,
        style: FocusBracketStyle,
        isVisible: Bool
    ) -> Bool {
        isRunning && hyprHeld && style != .off && !isVisible
    }
}

/// Compares complete, post-mutation snapshots and invokes the production
/// effect route once per logical config update.
final class ConfigUpdateCoordinator {
    var onEnabled: (Bool) -> Void = { _ in }
    var onKeybinds: ([Keybind]) -> Void = { _ in }
    var onHyprKey: (HyprKey) -> Void = { _ in }
    var onLayoutGeometry: (CGFloat, CGFloat) -> Void = { _, _ in }
    var onMaximumSplits: ([String: Int]) -> Void = { _ in }
    var onDisabledMonitors: (Set<String>) -> Void = { _ in }
    var onChrome: (RuntimeConfigState, ChromeConfigChanges) -> Void = { _, _ in }
    var onScratchpadRegion: (CGFloat) -> Void = { _ in }
    var onScratchpadEntryMode: (Bool) -> Void = { _ in }

    private var current: RuntimeConfigState
    private var observation: AnyCancellable?

    init(initial: RuntimeConfigState) {
        current = initial
    }

    func observe(_ config: UserConfig) {
        guard observation == nil else { return }
        observation = config.didApplyRuntimeChange.sink { [weak self, weak config] in
            guard let self, let config else { return }
            self.receive(RuntimeConfigState(config))
        }
    }

    func receive(_ next: RuntimeConfigState) {
        let previous = current
        guard next != previous else { return }
        current = next

        if next.enabled != previous.enabled { onEnabled(next.enabled) }
        if next.keybinds != previous.keybinds { onKeybinds(next.keybinds) }
        if next.hyprKey != previous.hyprKey { onHyprKey(next.hyprKey) }
        if next.gapSize != previous.gapSize || next.outerPadding != previous.outerPadding {
            onLayoutGeometry(next.gapSize, next.outerPadding)
        }
        if next.maxSplitsPerMonitor != previous.maxSplitsPerMonitor {
            onMaximumSplits(next.maxSplitsPerMonitor)
        }
        if next.disabledMonitors != previous.disabledMonitors {
            onDisabledMonitors(next.disabledMonitors)
        }

        var chrome: ChromeConfigChanges = []
        if next.showFocusBorder != previous.showFocusBorder { chrome.insert(.visibility) }
        if next.focusBorderColorHex != previous.focusBorderColorHex
            || next.floatingBorderColorHex != previous.floatingBorderColorHex {
            chrome.insert(.colors)
        }
        if next.focusBracketStyle != previous.focusBracketStyle
            || next.focusBracketColorHex != previous.focusBracketColorHex
            || next.focusBracketRadius != previous.focusBracketRadius
            || next.focusBracketThickness != previous.focusBracketThickness
            || next.focusBracketLength != previous.focusBracketLength {
            chrome.insert(.bracketAppearance)
        }
        if next.dimInactiveWindows != previous.dimInactiveWindows
            || next.dimIntensity != previous.dimIntensity {
            chrome.insert(.dimming)
        }
        if next.chromeFadeDurationSec != previous.chromeFadeDurationSec {
            chrome.insert(.fadeDuration)
        }
        if next.windowCornerRadius != previous.windowCornerRadius {
            chrome.insert(.windowCornerRadius)
        }
        if !chrome.isEmpty { onChrome(next, chrome) }

        if next.scratchpadRegionInset != previous.scratchpadRegionInset {
            onScratchpadRegion(next.scratchpadRegionInset)
        }
        if next.scratchpadTileByDefault != previous.scratchpadTileByDefault {
            onScratchpadEntryMode(next.scratchpadTileByDefault)
        }
    }
}
