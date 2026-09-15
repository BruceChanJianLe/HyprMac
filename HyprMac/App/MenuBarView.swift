// Menu bar dropdown contents and compact workspace label.

import SwiftUI
#if !HYPRMAC_DEBUG_VARIANT
import Sparkle
#endif

/// `MenuBarExtra` dropdown contents: status header, per-monitor
/// workspace state, and standard actions (Settings, Retile, Check
/// for Updates, Quit). Restyled to match the settings window — same
/// surface treatment, mono accent typography, cyan active-state
/// indicator. The label rendered in the menu bar itself is
/// `WorkspaceIndicatorLabel` (below).
struct MenuBarView: View {
    let appDelegate: AppDelegate
    @ObservedObject var config = UserConfig.shared
    @ObservedObject private var menuBarState = MenuBarState.shared
    @Environment(\.openWindow) private var openWindow
    #if !HYPRMAC_DEBUG_VARIANT
    let updater: SPUUpdater
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: HyprSpacing.md) {
            header
            workspacePanel
            actions
        }
        .padding(HyprSpacing.md)
        .frame(width: 280)
        .background(Color.hyprBackground)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: HyprSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("HYPRMAC")
                    .font(.hyprMono)
                    .kerning(2)
                    .foregroundStyle(Color.hyprTextPrimary)
                Text(config.enabled ? "Tiling active" : "Tiling paused")
                    .font(.hyprMonoXs)
                    .foregroundStyle(config.enabled ? Color.hyprCyan : Color.hyprTextTertiary)
            }
            Spacer(minLength: HyprSpacing.sm)
            Toggle("", isOn: $config.enabled)
                .toggleStyle(HyprToggleStyle())
                .labelsHidden()
        }
        .padding(.horizontal, HyprSpacing.xs)
    }

    // MARK: workspace panel

    @ViewBuilder
    private var workspacePanel: some View {
        if MenuBarPresentation.showsWorkspaceState(
            enabled: config.enabled,
            indicatorEnabled: true,
            hasData: menuBarState.hasData,
            monitors: menuBarState.monitors,
            scratchpadCount: menuBarState.scratchpadCount) {
            HyprPanel("Workspaces") {
                ForEach(menuBarState.monitors) { monitor in
                    monitorRow(monitor)
                }
                if menuBarState.scratchpadCount > 0 {
                    Rectangle()
                        .fill(Color.hyprSeparator)
                        .frame(height: 0.5)
                    HStack(spacing: 3) {
                        Image(systemName: "tray")
                            .font(.system(size: 10))
                        Text("\(menuBarState.scratchpadCount) stashed")
                            .font(.hyprMonoXs)
                        Spacer()
                    }
                    .foregroundStyle(Color.hyprMagenta)
                    .padding(.horizontal, HyprSpacing.md)
                    .padding(.vertical, HyprSpacing.sm)
                }
            }
        }
    }

    private func monitorRow(_ monitor: MenuBarMonitorSnapshot) -> some View {
        HStack(spacing: HyprSpacing.sm) {
            Image(systemName: monitor.isPortrait ? "rectangle.portrait" : "display")
                .font(.system(size: 11))
                .foregroundStyle(Color.hyprTextSecondary)
            Text(monitor.name)
                .font(.hyprBody)
                .foregroundStyle(Color.hyprTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: HyprSpacing.sm)
            Text("Workspace \(monitor.currentWorkspace)")
                .font(.hyprMonoSm)
                .foregroundStyle(Color.hyprCyan)
        }
        .padding(.horizontal, HyprSpacing.md)
        .padding(.vertical, HyprSpacing.sm)
    }

    // MARK: actions

    private var actions: some View {
        VStack(spacing: 1) {
            MenuBarRow("Keybinds", icon: "keyboard") {
                appDelegate.windowManager?.handleAction(.showKeybinds)
            } trailing: {
                HStack(spacing: 3) {
                    KeyChip("HYPR")
                    KeyChip("K")
                }
            }
            MenuBarRow("Settings…", icon: "gearshape") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            MenuBarRow("Tutorial", icon: "sparkles") {
                appDelegate.showTour()
            }
            MenuBarRow("Retile all spaces", icon: "rectangle.3.group") {
                NotificationCenter.default.post(name: .hyprMacRetileAll, object: nil)
            }
            #if !HYPRMAC_DEBUG_VARIANT
            MenuBarRow("Check for updates…", icon: "arrow.down.circle") {
                updater.checkForUpdates()
            } trailing: {
                Text("v\(appVersion)")
                    .font(.hyprMonoXs)
                    .foregroundStyle(Color.hyprTextTertiary)
            }
            #endif
            Rectangle()
                .fill(Color.hyprSeparator)
                .frame(height: 0.5)
                .padding(.vertical, HyprSpacing.xs)
            MenuBarRow("Quit HyprMac", icon: "power", destructive: true) {
                NSApp.terminate(nil)
            }
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}

// MARK: - menu row

private struct MenuBarRow<Trailing: View>: View {
    let label: String
    let icon: String
    let shortcut: String?
    let destructive: Bool
    let action: () -> Void
    let trailing: () -> Trailing

    @State private var hovering = false

    init(_ label: String,
         icon: String,
         shortcut: String? = nil,
         destructive: Bool = false,
         action: @escaping () -> Void,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.label = label
        self.icon = icon
        self.shortcut = shortcut
        self.destructive = destructive
        self.action = action
        self.trailing = trailing
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: HyprSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(destructive ? Color.red.opacity(0.85) : Color.hyprTextSecondary)
                    .frame(width: 16)
                Text(label)
                    .font(.hyprBody)
                    .foregroundStyle(destructive ? Color.red.opacity(0.95) : Color.hyprTextPrimary)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.hyprMono)
                        .foregroundStyle(Color.hyprTextSecondary)
                }
                trailing()
            }
            .padding(.horizontal, HyprSpacing.md)
            .padding(.vertical, HyprSpacing.sm - 1)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                    .fill(hovering ? Color.hyprTextTertiary.opacity(0.10) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(HyprMotion.snap, value: hovering)
    }
}

// Bridge for the menu bar label between WindowManager (which knows the
// workspace state but is not available at app init) and the SwiftUI
// MenuBarExtra label (which is built before WindowManager exists).
// WindowManager.updateMenuBarState writes to .shared after every poll;
// WorkspaceIndicatorLabel observes it.
class MenuBarState: ObservableObject {
    static let shared = MenuBarState()
    @Published var monitors: [MenuBarMonitorSnapshot] = []
    @Published var hasData = false
    /// Number of windows in the scratchpad (0 = hide the tray glyph).
    @Published var scratchpadCount = 0
    /// Whether the scratchpad layer is currently summoned (filled tray).
    @Published var scratchpadVisible = false
}

struct MenuBarMonitorSnapshot: Equatable, Identifiable {
    let id: Int
    let name: String
    let currentWorkspace: Int
    let isPortrait: Bool
}

enum MenuBarPresentation {
    static func compactWorkspaceText(_ monitors: [MenuBarMonitorSnapshot]) -> String {
        monitors.map { String($0.currentWorkspace) }.joined(separator: " · ")
    }

    static func monitorSummary(_ monitors: [MenuBarMonitorSnapshot]) -> String {
        monitors.map { "\($0.name): Workspace \($0.currentWorkspace)" }
            .joined(separator: "\n")
    }

    static func showsWorkspaceState(enabled: Bool, indicatorEnabled: Bool,
                                    hasData: Bool, monitors: [MenuBarMonitorSnapshot],
                                    scratchpadCount: Int) -> Bool {
        enabled && indicatorEnabled && hasData
            && (!monitors.isEmpty || scratchpadCount > 0)
    }
}

// Shows current workspaces in left-to-right monitor order, plus stash state.
struct WorkspaceIndicatorLabel: View {
    @ObservedObject private var config = UserConfig.shared
    @ObservedObject private var state = MenuBarState.shared

    var body: some View {
        let workspaceText = MenuBarPresentation.compactWorkspaceText(state.monitors)
        if MenuBarPresentation.showsWorkspaceState(
            enabled: config.enabled,
            indicatorEnabled: config.showMenuBarIndicator,
            hasData: state.hasData,
            monitors: state.monitors,
            scratchpadCount: state.scratchpadCount) {
            HStack(spacing: 5) {
                if !workspaceText.isEmpty {
                    Image(systemName: "display")
                    Text(workspaceText)
                        .font(.system(size: 12, weight: .regular))
                }
                if state.scratchpadCount > 0 {
                    Image(systemName: state.scratchpadVisible ? "tray.fill" : "tray")
                    if state.scratchpadCount > 1 {
                        Text("\(state.scratchpadCount)")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
            }
            .help(MenuBarPresentation.monitorSummary(state.monitors))
        } else {
            Image(systemName: "rectangle.split.2x2")
        }
    }
}

extension Notification.Name {
    static let hyprMacRetileAll = Notification.Name("hyprMacRetileAll")
    static let hyprMacWorkspaceChanged = Notification.Name("hyprMacWorkspaceChanged")
    // posted once per dispatched hotkey action; Tour's try-it hint observes it
    static let hyprMacActionDispatched = Notification.Name("hyprMacActionDispatched")
}
