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
            title: "Splits Survive Tab Switches",
            description: "Resize a split, switch native tabs in Ghostty or Chrome, and the split stays where you put it. Hiding an app with Cmd+H and bringing it back keeps the split too. Before, the hidden window left the layout and the returning one came back at 50/50.",
            credit: "@joops"
        ),
        WhatsNewFeature(
            icon: "rectangle.roundedtop",
            title: "Window Corners Are Adjustable",
            description: "Window corner radius now starts from a suggested value until you set one yourself. The Suggested button clears your override, and the red swap-rejection border keeps its width when the radius changes.",
            credit: "@Amin-El-Sayed"
        ),
        WhatsNewFeature(
            icon: "checkmark.shield",
            title: "Config Survives Version Mismatches",
            description: "A keybind that an older HyprMac build does not recognise is now skipped instead of resetting the whole config. This matters when config.json is synced over iCloud between Macs running different versions.",
            tint: .magenta
        ),
    ]
}

enum WelcomeContent {
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
        if bind.modifiers.contains(.hypr) { parts.append(hyprKey.badgeLabel) }
        if bind.modifiers.contains(.control) { parts.append("⌃") }
        if bind.modifiers.contains(.option) { parts.append("⌥") }
        if bind.modifiers.contains(.shift) { parts.append("⇧") }
        if bind.modifiers.contains(.command) { parts.append("⌘") }
        parts.append(bind.keyCodeName)
        return parts.joined(separator: " ")
    }
}
