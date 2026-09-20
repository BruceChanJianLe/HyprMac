// Per-app placement rules. A rule pins every new window of one app to a
// chosen workspace, instead of letting it land on whatever workspace is
// visible on the display it opened on.

import Foundation

/// One app-to-workspace pin. Keyed by bundle id, so an app holds at most
/// one rule - `id` is the bundle id for exactly that reason.
///
/// A rule is consulted when a window is placed: at admission
/// (`ActionDispatcher.pinnedWorkspace`), when startup or Retile All
/// redistributes every window, and on demand through
/// `Action.applyWindowRules`. Between those moments it is not a tether:
/// move a pinned window elsewhere and it stays there until the next pass.
struct WindowRule: Codable, Equatable, Identifiable {
    var id: String { bundleID }

    let bundleID: String
    let workspace: Int

    init(bundleID: String, workspace: Int) {
        self.bundleID = bundleID
        self.workspace = workspace
    }
}
