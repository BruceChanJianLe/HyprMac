// Per-app placement rules. A rule pins every new window of one app to a
// chosen workspace, instead of letting it land on whatever workspace is
// visible on the display it opened on.

import Foundation

/// One app-to-workspace pin. Keyed by bundle id, so an app holds at most
/// one rule - `id` is the bundle id for exactly that reason.
///
/// Rules apply at admission time only (see
/// `ActionDispatcher.pinnedWorkspace`). Windows already placed are left
/// where they are: a rule is a statement about where new windows go, not
/// a tether that keeps dragging a window back.
struct WindowRule: Codable, Equatable, Identifiable {
    var id: String { bundleID }

    let bundleID: String
    let workspace: Int

    init(bundleID: String, workspace: Int) {
        self.bundleID = bundleID
        self.workspace = workspace
    }
}
