// The explicit-request side of min-size memory: what a user's own move or
// float→tile does about a refusal that only learned bounds produced, and the
// markers that carry that request across to a hidden workspace's reveal.

import Cocoa

/// Bookkeeping for explicit revalidation of learned minima.
///
/// A refusal by learned bounds is a refusal by memory. When the user asks
/// again — a move to another workspace, a float→tile toggle — that memory
/// gets one chance to be wrong, on one private candidate, with the bounds of
/// the incoming window and the destination's tenants set aside.
///
/// Where the destination is visible the whole question is settled on the
/// spot: the attempt runs, and only an accepted layout commits the move. A
/// hidden destination cannot be settled that way, because unparking its
/// tenants over the visible workspace to run an experiment is exactly what
/// the user did not ask for. So the move follows the ordinary assignment and
/// parking, and this holds a marker until that workspace is shown. The reveal
/// retile is the attempt; there is one of them, and after it the marker is
/// gone whatever the answer.
///
/// Nothing here schedules anything. The reveal is the user's own next
/// workspace switch, so an ordinary poll can never turn into a min-size
/// probe.
///
/// Threading: main-thread only.
final class MinimaRevalidation {

    /// What an explicit request does about an outlook.
    enum Decision: Equatable {
        /// the destination takes it as things stand.
        case admit
        /// the destination is on screen: make the one attempt now and commit
        /// only if it is accepted.
        case revalidateHere
        /// the destination is hidden: park as usual and leave a marker for
        /// the reveal.
        case parkForReveal
        /// refused for something an attempt cannot change.
        case refuse
    }

    /// A move that is waiting for its destination to be shown.
    struct Pending: Equatable {
        let workspace: Int
        let screen: NSScreen
        /// where the window came from, so a cancellation knows what it is
        /// undoing and the log can say it.
        let sourceWorkspace: Int?
        let sourceScreen: NSScreen
    }

    // MARK: - seams

    /// the window's current workspace assignment, to catch a marker whose
    /// window has since gone somewhere else.
    var workspaceFor: (CGWindowID) -> Int? = { _ in nil }
    /// whether the user has floated the window since. A floater is not
    /// admitted by a tiling pass, so its marker has nothing left to do.
    var isFloating: (CGWindowID) -> Bool = { _ in false }

    // MARK: - state

    private var pending: [CGWindowID: Pending] = [:]

    /// Windows whose explicit move is waiting on a reveal.
    var pendingWindowIDs: Set<CGWindowID> { Set(pending.keys) }

    func marker(for windowID: CGWindowID) -> Pending? { pending[windowID] }

    // MARK: - the decision

    /// What an explicit request should do, given what the fit check saw.
    static func decide(_ outlook: TilingEngine.AdmissionOutlook,
                       destinationVisible: Bool) -> Decision {
        switch outlook {
        case .fits: return .admit
        case .refused: return .refuse
        case .revalidatable: return destinationVisible ? .revalidateHere : .parkForReveal
        }
    }

    // MARK: - hidden destinations

    /// Remember that `windowID` was let through to a hidden `workspace` on
    /// learned bounds alone. Replaces any marker it already had: the user's
    /// latest request is the one that counts.
    func park(_ windowID: CGWindowID, toWorkspace workspace: Int, screen: NSScreen,
              sourceWorkspace: Int?, sourceScreen: NSScreen) {
        pending[windowID] = Pending(workspace: workspace, screen: screen,
                                    sourceWorkspace: sourceWorkspace, sourceScreen: sourceScreen)
        hyprLog(.notice, .tiling, "minima revalidation parked: \(windowID) → ws\(workspace)"
                + " from ws\(sourceWorkspace.map(String.init) ?? "none")"
                + " — verified when that workspace is shown")
    }

    /// Windows whose marker this retile of `(workspace, screen)` should
    /// spend. Drops any marker whose window has since been reassigned or
    /// floated — both are the user acting again, and neither leaves anything
    /// for the reveal to check.
    func incomingIDs(forWorkspace workspace: Int, screen: NSScreen) -> Set<CGWindowID> {
        var due: Set<CGWindowID> = []
        for (id, record) in pending where record.workspace == workspace && record.screen == screen {
            if workspaceFor(id) != workspace {
                cancel(id, reason: "moved again")
            } else if isFloating(id) {
                cancel(id, reason: "user floated it")
            } else {
                due.insert(id)
            }
        }
        return due
    }

    /// The reveal happened. The markers are spent either way: an accepted
    /// layout has already lowered whatever it disproved, and a refused one
    /// hands the window to the bounded admission recovery, which owns it from
    /// there. Neither outcome earns a second bypass.
    func noteReveal(_ consumed: Set<CGWindowID>, accepted: Set<CGWindowID>) {
        guard !consumed.isEmpty else { return }
        for id in consumed { pending.removeValue(forKey: id) }
        hyprLog(.notice, .tiling, "minima revalidation revealed:"
                + " spent=\(Self.list(consumed)) tiled=\(Self.list(consumed.intersection(accepted)))")
    }

    // MARK: - cancellation

    /// Drop one marker. The user's own later actions: another move, a float,
    /// a close.
    func cancel(_ windowID: CGWindowID, reason: String) {
        guard pending.removeValue(forKey: windowID) != nil else { return }
        hyprLog(.notice, .tiling, "minima revalidation cancelled: \(windowID) reason=\(reason)")
    }

    /// Drop everything. A stop or a display change makes every recorded
    /// source and destination screen stale.
    func cancelAll(reason: String) {
        guard !pending.isEmpty else { return }
        let ids = Set(pending.keys)
        pending.removeAll()
        hyprLog(.notice, .tiling, "minima revalidation cancelled: ids=\(Self.list(ids)) reason=\(reason)")
    }

    /// The window is gone. Ordinary cleanup, no log of its own.
    func forget(_ windowID: CGWindowID) {
        pending.removeValue(forKey: windowID)
    }

    private static func list(_ ids: Set<CGWindowID>) -> String {
        "[" + ids.sorted().map(String.init).joined(separator: ", ") + "]"
    }
}
