// Pure formatting for `WindowManager.dumpState`. Takes plain values —
// screen names, id sets, the workspace map — so the block can be
// asserted line for line without AppKit or a live tree.

import CoreGraphics

/// Renders one on-demand state dump as a list of log lines.
///
/// Order is fixed: one line per enabled screen, then each workspace
/// 1...9 that has at least one assignment (ascending), then the
/// scratchpad, then cache totals. Workspaces with no assignment are
/// omitted entirely.
///
/// Window titles never enter these lines — ids only.
struct StateDumpFormatter {

    /// An enabled screen and the workspace currently shown on it.
    struct ScreenState {
        let name: String
        let visibleWorkspace: Int
    }

    let screens: [ScreenState]
    /// Workspace → static home screen name.
    let homeScreenNames: [Int: String]
    let visibleWorkspaces: Set<Int>
    /// Window → workspace. Workspace 0 (scratchpad) entries are skipped
    /// here; the scratchpad gets its own line.
    let assignments: [CGWindowID: Int]
    let hidden: Set<CGWindowID>
    let reserved: Set<CGWindowID>
    let floating: Set<CGWindowID>
    /// Workspace → leaf window ids of its tree on its home screen.
    let trees: [Int: [CGWindowID]]
    let scratchpad: Set<CGWindowID>
    let knownCount: Int

    private static let workspaceRange = 1...9

    func lines() -> [String] {
        var out = screens.map { "screen=\($0.name) visible=ws\($0.visibleWorkspace)" }

        var members: [Int: [CGWindowID]] = [:]
        for (id, workspace) in assignments where Self.workspaceRange.contains(workspace) {
            members[workspace, default: []].append(id)
        }

        for workspace in members.keys.sorted() {
            let assigned = members[workspace]!.sorted()
            let home = homeScreenNames[workspace] ?? "?"
            out.append("ws\(workspace) home=\(home)"
                + " visible=\(visibleWorkspaces.contains(workspace))"
                + " assigned=\(Self.list(assigned))"
                + " hidden=\(Self.list(assigned.filter(hidden.contains)))"
                + " reserved=\(Self.list(assigned.filter(reserved.contains)))"
                + " floating=\(Self.list(assigned.filter(floating.contains)))"
                + " tree(\(home))=\(Self.list(trees[workspace] ?? []))")
        }

        out.append("scratchpad=\(Self.list(scratchpad.sorted()))")
        out.append("known=\(knownCount) hidden=\(hidden.count)"
            + " reserved=\(reserved.count) floating=\(floating.count)")
        return out
    }

    private static func list(_ ids: [CGWindowID]) -> String {
        "[" + ids.map(String.init).joined(separator: ", ") + "]"
    }
}
