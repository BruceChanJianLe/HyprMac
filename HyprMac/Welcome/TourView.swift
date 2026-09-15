// Single Tour shell that renders both the first-run walkthrough and
// the post-update "What's New" page. Styled on-system with Hypr tokens
// (mockups 1k / 1l): solid dark chassis, cyan accents, mono wordmark.

import SwiftUI

// MARK: - shell

/// 520×440 shell shared by the tutorial and what's-new. Header (icon +
/// wordmark + right slot) · content page · footer. Mode picks the page
/// set and footer.
struct TourView: View {
    let mode: WelcomeMode
    let onDismiss: () -> Void

    @State private var page = 0
    @ObservedObject private var config = UserConfig.shared
    @StateObject private var loginItem = LoginItemController()

    private var pageCount: Int { mode == .firstRun ? 7 : 1 }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: 520, height: 440)
        .background(Color.hyprBackground)
    }

    // MARK: header

    private var header: some View {
        HStack {
            HStack(spacing: 10) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                Text(mode == .firstRun ? "HYPRMAC TUTORIAL" : "HYPRMAC")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(Color.hyprTextPrimary.opacity(0.7))
            }
            Spacer()
            headerSlot
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    @ViewBuilder
    private var headerSlot: some View {
        switch mode {
        case .firstRun:
            // tutorial page counter
            Text("\(page + 1) / \(pageCount)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.hyprTextPrimary.opacity(0.35))
        case .whatsNew:
            // cyan version chip
            Text(WelcomeContent.appVersion)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.hyprCyan)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                        .fill(Color.hyprCyan.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                        .strokeBorder(Color.hyprCyan.opacity(0.3), lineWidth: 1)
                )
        }
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .firstRun:
            Group {
                switch page {
                case 0: TourHeroPage(config: config)
                case 1: TourWindowPage(config: config)
                case 2: TourFocusPage(config: config)
                case 3: TourWorkspacesPage(config: config)
                case 4: TourWorkspaceGlyphsPage()
                case 5: TourFinishPage(config: config)
                default: LoginItemPromptPage(controller: loginItem)
                }
            }
            .transition(.opacity)
            .id(page)
        case .whatsNew:
            WhatsNewPage()
        }
    }

    // MARK: footer

    @ViewBuilder
    private var footer: some View {
        switch mode {
        case .firstRun:
            if page == pageCount - 1 {
                HStack {
                    Button("Not now") { onDismiss() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.hyprTextPrimary.opacity(0.4))

                    Spacer()

                    if loginItem.state == .enabled {
                        CyanButton("Continue") { onDismiss() }
                    } else if loginItem.instructionText != nil {
                        CyanButton("Open Login Items") { loginItem.openLoginItems() }
                    } else {
                        CyanButton("Yes, Launch at Login") { loginItem.enable() }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            } else {
                HStack {
                    Button("Skip") {
                        withAnimation(HyprMotion.glide) { page = pageCount - 1 }
                    }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.hyprTextPrimary.opacity(0.4))

                    Spacer()

                    HStack(spacing: 6) {
                        ForEach(0..<pageCount, id: \.self) { i in
                            Capsule()
                                .fill(i == page ? Color.hyprCyan : Color.hyprTextPrimary.opacity(0.18))
                                .frame(width: 6, height: 6)
                                .onTapGesture {
                                    withAnimation(HyprMotion.glide) { page = i }
                                }
                        }
                    }

                    Spacer()

                    CyanButton("Next") {
                        withAnimation(HyprMotion.glide) { page += 1 }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        case .whatsNew:
            HStack {
                Spacer()
                CyanButton("Continue") { onDismiss() }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }
}

// MARK: - first-run final page: launch at login

private struct LoginItemPromptPage: View {
    @ObservedObject var controller: LoginItemController

    var body: some View {
        VStack(spacing: 0) {
            HeroGlyph(icon: controller.state == .enabled ? "checkmark.circle" : "power")
                .padding(.bottom, 20)

            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.hyprTextPrimary)

            Text(message)
                .font(.system(size: 12.5))
                .lineSpacing(4)
                .foregroundStyle(Color.hyprTextPrimary.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 370)
                .padding(.top, 9)

            if let instruction = controller.instructionText {
                Text(instruction)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.hyprTextPrimary.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 48)
        .onAppear { controller.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refresh()
        }
    }

    private var title: String {
        controller.state == .enabled
            ? "\(controller.appName) launches at login"
            : "Launch \(controller.appName) at login?"
    }

    private var message: String {
        switch controller.state {
        case .enabled:
            return "You’re all set. \(controller.appName) will be ready when you sign in."
        case .requiresApproval:
            return "macOS needs your approval before \(controller.appName) can launch automatically."
        case .failed:
            return "Automatic setup didn’t finish. You can enable it in System Settings."
        case .notEnabled:
            return "\(controller.appName) can start automatically so your window shortcuts are ready after you sign in."
        }
    }
}

// MARK: - shared cyan filled button (dark text on cyan, radius 6)

private struct CyanButton: View {
    let label: String
    let action: () -> Void
    init(_ label: String, action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color(red: 0x0b/255, green: 0x14/255, blue: 0x17/255))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                        .fill(Color.hyprCyan)
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }
}

// MARK: - first-run page 1: Hypr key hero + live try-it

private struct TourHeroPage: View {
    @ObservedObject var config: UserConfig
    // flips once the app reports a focusDirection while this page is up
    @State private var tried = false

    var body: some View {
        VStack(spacing: 0) {
            keycap
                .padding(.bottom, 22)

            Text(config.hyprKey == .capsLock
                 ? "Caps Lock is your HYPR Key by Default."
                 : "\(config.hyprKey.displayName) is your HYPR Key.")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.hyprTextPrimary)
                .multilineTextAlignment(.center)

            Text("This is your portal into HyprMac! All shortcuts start with this key.")
                .font(.system(size: 12.5))
                .lineSpacing(4)
                .foregroundStyle(Color.hyprTextPrimary.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.top, 8)

            tryItPill
                .padding(.top, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 48)
        // observe dispatched actions; flip on any focusDirection
        .onReceive(NotificationCenter.default.publisher(for: .hyprMacActionDispatched)) { note in
            if note.userInfo?["action"] as? String == "focusDirection" {
                withAnimation(HyprMotion.snap) { tried = true }
            }
        }
    }

    // 150×58 rounded key with cyan border + 3pt bottom edge + soft glow
    private var keycap: some View {
        HStack(spacing: 8) {
            Text(config.hyprKey.badgeLabel)
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.hyprCyan)
            Text(config.hyprKey.displayName.uppercased())
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(1)
                .foregroundStyle(Color.hyprTextPrimary.opacity(0.7))
        }
        .frame(width: 150, height: 58)
        .background(
            RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                .fill(Color.hyprSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                .strokeBorder(Color.hyprCyan.opacity(0.5), lineWidth: 1)
        )
        .overlay(alignment: .bottom) {
            // brighter 3pt bottom edge
            RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                .fill(Color.hyprCyan.opacity(0.7))
                .frame(height: 3)
                .mask(
                    RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                )
        }
        .shadow(color: Color.hyprCyan.opacity(0.22), radius: 17)
    }

    // dashed cyan capsule that swaps to a ✓ confirmed state
    private var tryItPill: some View {
        Group {
            if tried {
                HStack(spacing: 8) {
                    Text("✓")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.hyprCyan)
                    Text("Nice! You switched windows.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.hyprCyan)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: HyprRadius.sm + 4, style: .continuous)
                        .fill(Color.hyprCyan.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HyprRadius.sm + 4, style: .continuous)
                        .strokeBorder(Color.hyprCyan.opacity(0.55), lineWidth: 1)
                )
            } else {
                HStack(spacing: 8) {
                    if let focusChord {
                        Text("Try it now")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.hyprTextPrimary.opacity(0.6))
                        MiniKey(focusChord)
                    } else {
                        Text("Add Focus Right in Settings → Keys to try it here.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.hyprTextPrimary.opacity(0.6))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: HyprRadius.sm + 4, style: .continuous)
                        .fill(Color.hyprCyan.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HyprRadius.sm + 4, style: .continuous)
                        .strokeBorder(
                            Color.hyprCyan.opacity(0.35),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                )
            }
        }
    }

    private var focusChord: String? {
        WelcomeContent.chord(in: config.keybinds, hyprKey: config.hyprKey) {
            if case .focusDirection(.right) = $0 { return true }
            return false
        }
    }
}

// MARK: - first-run page 2: tiled and floating windows

private struct TourWindowPage: View {
    @ObservedObject var config: UserConfig

    var body: some View {
        TourInfoPage(
            icon: "rectangle.split.2x1",
            title: "Tiled and floating windows",
            copy: Text("New windows join the tiling layout automatically. A floating window stays above the tiles and moves freely."),
            bullets: [
                ("hand.draw", "Drag a tile by its title bar to insert it. Hold HYPR during the drag to swap with another tile in the same workspace."),
                ("diamond", floatingInstruction),
                ("arrow.up.left.and.arrow.down.right", "Drag or resize a floating window with the app's normal title bar and edges."),
            ],
            magentaBulletIndex: 1
        )
    }

    private var floatingInstruction: String {
        guard let chord = WelcomeContent.chord(in: config.keybinds, hyprKey: config.hyprKey, matching: {
            if case .toggleFloating = $0 { return true }
            return false
        }) else { return "Add Toggle Floating in Settings → Keys if you want a shortcut." }
        return "Press \(chord) to toggle the focused window between tiled and floating."
    }
}

// small cyan key chip used inside the try-it pill
private struct MiniKey: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.hyprCyan)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                    .fill(Color.hyprCyan.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                    .strokeBorder(Color.hyprCyan.opacity(0.35), lineWidth: 1)
            )
    }
}

// MARK: - first-run page 3: Focus

private struct TourFocusPage: View {
    @ObservedObject var config: UserConfig

    var body: some View {
        TourInfoPage(
            icon: "arrow.up.and.down.and.arrow.left.and.right",
            title: "Move between windows",
            copy: attributed,
            bullets: focusBullets
        )
    }

    private var focusBullets: [(icon: String, text: String)] {
        let directionText: String
        if let focusChord, let swapChord {
            directionText = "\(focusChord) takes you to the window on your left. \(swapChord) swaps places with it. Try the other arrows too."
        } else {
            directionText = "Add Focus Direction and Swap Direction shortcuts in Settings → Keys."
        }
        var result = [("arrow.left.arrow.right", directionText)]
        if config.focusFollowsMouse {
            result.append(("cursorarrow.motionlines", "Move the pointer over a window to focus it."))
        } else {
            result.append(("cursorarrow.motionlines", "Turn on focus follows the mouse in General settings, then move the pointer over a window to focus it."))
        }
        if config.focusBracketStyle != .off {
            result.append(("rectangle.dashed", "Hold \(config.hyprKey.displayName) to show corner marks on the focused window."))
        } else {
            result.append(("rectangle.dashed", "You can turn on corner marks in Layout settings."))
        }
        return result
    }

    private var focusChord: String? {
        WelcomeContent.chord(in: config.keybinds, hyprKey: config.hyprKey) {
            if case .focusDirection(.left) = $0 { return true }
            return false
        }
    }

    private var swapChord: String? {
        WelcomeContent.chord(in: config.keybinds, hyprKey: config.hyprKey) {
            if case .swapDirection(.left) = $0 { return true }
            return false
        }
    }

    private var attributed: Text {
        Text("The focused window is the one you’re using right now. Here’s how to get around without clicking.")
    }
}

// MARK: - first-run page 4: Workspaces

private struct TourWorkspacesPage: View {
    @ObservedObject var config: UserConfig

    var body: some View {
        TourInfoPage(
            icon: "square.stack.3d.up",
            title: "Workspaces",
            copy: attributed,
            bullets: [
                ("number", workspaceInstruction),
                ("menubar.rectangle", "Check the menu bar to see which workspace each monitor is showing."),
                ("square.stack", "Your windows stay on their workspace when you switch."),
            ]
        )
    }

    private var workspaceInstruction: String {
        let switchChord = WelcomeContent.chord(in: config.keybinds, hyprKey: config.hyprKey) {
            if case .switchWorkspace(1) = $0 { return true }
            return false
        }
        let sendChord = WelcomeContent.chord(in: config.keybinds, hyprKey: config.hyprKey) {
            if case .moveToWorkspace(1) = $0 { return true }
            return false
        }
        guard let switchChord, let sendChord else {
            return "You can add workspace shortcuts in Settings → Keys."
        }
        return "\(switchChord) opens workspace 1. \(sendChord) sends the focused window there. Try another number for a different workspace."
    }

    private var attributed: Text {
        Text("Workspaces let you keep separate groups of windows. Each monitor shows one group at a time.")
    }
}

// MARK: - first-run page 5: workspace strip

private struct TourWorkspaceGlyphsPage: View {
    private let examples: [(number: Int, glyph: String, color: Color)] = [
        (1, "●", .hyprCyan), (2, "◆", .hyprMagenta), (3, "○", .hyprCyan),
        (4, "◇", .hyprMagenta), (5, "·", .hyprTextPrimary.opacity(0.3)),
    ]
    private let legend: [(glyph: String, label: String, color: Color)] = [
        ("●", "Shown now", .hyprCyan),
        ("◆", "Shown now · has floating windows", .hyprMagenta),
        ("○", "Windows waiting", .hyprCyan),
        ("◇", "Windows waiting · has floating windows", .hyprMagenta),
        ("·", "Empty workspace", .hyprTextPrimary.opacity(0.3)),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Text("Read the workspace strip")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.hyprTextPrimary)
            Text("Each position matches its workspace number.")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.hyprTextPrimary.opacity(0.55))
                .padding(.top, 8)

            HStack(spacing: 18) {
                ForEach(examples, id: \.number) { item in
                    VStack(spacing: 3) {
                        Text("\(item.number)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Color.hyprTextPrimary.opacity(0.4))
                        Text(item.glyph)
                            .font(.system(size: 19, weight: .medium, design: .monospaced))
                            .foregroundStyle(item.color)
                    }
                    .frame(width: 28)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous).fill(Color.hyprSurface))
            .overlay(RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous).strokeBorder(Color.hyprTextPrimary.opacity(0.1), lineWidth: 1))
            .padding(.top, 16)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(legend.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 10) {
                        Text(item.glyph)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundStyle(item.color)
                            .frame(width: 18)
                        Text(item.label)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.hyprTextPrimary.opacity(0.75))
                    }
                }
            }
            .frame(width: 300, alignment: .leading)
            .padding(.top, 15)

            Text("Filled symbols are currently shown. More than one can be filled when you use multiple monitors.")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.hyprTextPrimary.opacity(0.5))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 44)
    }
}

// MARK: - first-run page 6: Finish → keymap

private struct TourFinishPage: View {
    @ObservedObject var config: UserConfig

    var body: some View {
        VStack(spacing: 0) {
            HeroGlyph(icon: "keyboard")
                .padding(.bottom, 20)

            Text("You’re ready to go!")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.hyprTextPrimary)

            Group {
                if let keymapChord {
                    HStack(spacing: 6) {
                        Text("Press")
                        KeyChip(keymapChord)
                        Text("anytime")
                    }
                } else {
                    Text("Open Keybinds from the menu bar, or add Show Keybinds in Settings → Keys.")
                }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Color.hyprTextPrimary.opacity(0.55))
            .multilineTextAlignment(.center)
            .padding(.top, 10)

            Text("You don’t have to memorize everything. Your shortcuts and this tutorial are always here, or in the menu bar.")
                .font(.system(size: 12.5))
                .lineSpacing(4)
                .foregroundStyle(Color.hyprTextPrimary.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .padding(.top, 8)

            Text(pauseInstruction)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.hyprTextPrimary.opacity(0.7))
                .padding(.top, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 48)
    }

    private var keymapChord: String? {
        WelcomeContent.chord(in: config.keybinds, hyprKey: config.hyprKey, matching: {
            if case .showKeybinds = $0 { return true }
            return false
        })
    }

    private var pauseInstruction: String {
        guard let chord = WelcomeContent.chord(in: config.keybinds, hyprKey: config.hyprKey, matching: {
            if case .toggleTiling = $0 { return true }
            return false
        }) else { return "Add Pause / Resume Tiling in Settings → Keys when you want a break." }
        return "If things get in your way, press \(chord) to pause tiling. Press it again when you’re ready."
    }
}

// MARK: - shared info page (hero glyph + title + body + bullet rows)

private struct TourInfoPage: View {
    let icon: String
    let title: String
    let copy: Text
    let bullets: [(icon: String, text: String)]
    var magentaBulletIndex: Int? = nil

    var body: some View {
        VStack(spacing: 0) {
            HeroGlyph(icon: icon)
                .padding(.bottom, 18)

            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.hyprTextPrimary)

            copy
                .font(.system(size: 12.5))
                .lineSpacing(4)
                .foregroundStyle(Color.hyprTextPrimary.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(bullets.enumerated()), id: \.offset) { idx, row in
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: row.icon)
                            .font(.system(size: 12))
                            .foregroundStyle(magentaBulletIndex == idx ? Color.hyprMagenta : Color.hyprCyan)
                            .frame(width: 18)
                        Text(row.text)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.hyprTextPrimary.opacity(0.75))
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: 380)
            .padding(.top, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 44)
    }
}

// MARK: - cyan-tinted rounded-square hero glyph

private struct HeroGlyph: View {
    let icon: String

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(Color.hyprCyan)
            .frame(width: 52, height: 52)
            .background(
                RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                    .fill(Color.hyprCyan.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                    .strokeBorder(Color.hyprCyan.opacity(0.3), lineWidth: 1)
            )
    }
}

// MARK: - what's-new page (mockup 1l)

private struct WhatsNewPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What's new")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.hyprTextPrimary)
                .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(WhatsNewFeatures.current, id: \.title) { feature in
                        changelogRow(feature)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 24)
        .padding(.top, 18)
    }

    private func changelogRow(_ feature: WhatsNewFeature) -> some View {
        let tint: Color = feature.tint == .magenta ? .hyprMagenta : .hyprCyan
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: feature.icon)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(tint.opacity(0.3), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(feature.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.hyprTextPrimary)
                Text(feature.description)
                    .font(.system(size: 11))
                    .lineSpacing(3)
                    .foregroundStyle(Color.hyprTextPrimary.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                if let credit = feature.credit {
                    Text("Contributed by \(credit)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(tint.opacity(0.85))
                        .padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.hyprSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.hyprTextPrimary.opacity(0.08), lineWidth: 1)
        )
    }
}
