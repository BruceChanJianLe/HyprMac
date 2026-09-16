// Data tables for the Welcome / Tour window.

import SwiftUI

// MARK: - what's new feature list
// Update this array before each release with features from git log;
// see CLAUDE.md "Release Feature List" for the workflow.

/// Accent used for a changelog row's icon tile.
enum WhatsNewTint {
    case cyan   // default
    case magenta // floating / scratchpad features
}

/// One row in the "What's New" page: icon, title, description, tint.
struct WhatsNewFeature {
    let icon: String
    let title: String
    let description: String
    var tint: WhatsNewTint = .cyan
    /// github handle of an outside contributor, shown under the description
    var credit: String? = nil
}

enum WhatsNewFeatures {
    // update this before each release — see CLAUDE.md instructions
    static let current: [WhatsNewFeature] = [
        WhatsNewFeature(
            icon: "rectangle.split.2x1",
            title: "Hyprland-Style Tiling",
            description: "Drag a tiled window to an edge of another tile to place it there and reshape your layout. Hold Hypr while dragging when you want to swap the two tiles instead."
        ),
        WhatsNewFeature(
            icon: "slider.horizontal.3",
            title: "Settings, Rebuilt",
            description: "The redesigned Settings app makes displays, workspaces, appearance, apps, and keybinds easier to understand and customize. Window corners now support a suggested radius or your own override."
        ),
        WhatsNewFeature(
            icon: "keyboard",
            title: "A Clearer HYPR+K Menu",
            description: "The keybind reference is now a larger, more readable three-column guide, with navigation and apps on the left, window management in the center, and workspaces on the right. Toggle Float now defaults to HYPR+T."
        ),
        WhatsNewFeature(
            icon: "checkmark.shield",
            title: "Safer Tiling and Recovery",
            description: "Frame changes are verified before a layout is committed. HyprMac can recover portrait startup layouts by choosing a fitting split direction, and it makes one bounded retry after a timed-out Accessibility call, only after restoring the original frames.",
            tint: .magenta
        ),
    ]
}

enum WelcomeContent {
    static let productURL = URL(string: "https://hyprmac.app/")!

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    static func chord(
        in keybinds: [Keybind],
        hyprKey: HyprKey,
        matching predicate: (Action) -> Bool
    ) -> String? {
        guard let bind = keybinds.first(where: { predicate($0.action) }) else { return nil }
        var parts: [String] = []
        if bind.modifiers.contains(.hypr) { parts.append("HYPR") }
        if bind.modifiers.contains(.control) { parts.append("⌃") }
        if bind.modifiers.contains(.option) { parts.append("⌥") }
        if bind.modifiers.contains(.shift) { parts.append("⇧") }
        if bind.modifiers.contains(.command) { parts.append("⌘") }
        parts.append(bind.keyCodeName)
        return parts.joined(separator: " ")
    }
}
