// One bounded retry for a newcomer a failed admission stranded, then an
// explicit float in place. Nothing here routes a window to another
// workspace — that stays with the pre-insertion overflow path.

import Cocoa

/// Bounded recovery for windows a failed admission left outside the tree.
///
/// A tiling pass that inserts a new window and is then refused by the screen
/// keeps its prior tree, which means the newcomer is visible, assigned, not
/// floating and in no tree at all. This owns the two steps that finish it:
/// one retry about 250 ms later under a fresh owned context with the minima
/// that attempt itself observed ignored, and, if that is refused too, an
/// explicit float where the window already is.
///
/// The retry never re-arms itself. A window that is unreadable or on a
/// hidden workspace when its turn comes keeps its place in the pending set
/// and waits for a real discovery or activation event instead of a new
/// timer, so nothing spins and no frame is invented.
///
/// Threading: main-thread only.
final class AdmissionRecovery {

    /// What a pending window is waiting for.
    enum Phase: Equatable {
        /// its one retry is armed.
        case awaitingRetry
        /// the window could not be judged when its turn came — unreadable,
        /// or its workspace was hidden. No timer is running for it.
        case awaitingEvidence
    }

    /// What one recovery attempt found out.
    struct AttemptResult {
        /// newcomers the attempt left in the published tree.
        var placed: Set<CGWindowID> = []
        /// why the attempt was refused, for the fallback log line.
        var failure: FrameSizingFailure?
    }

    private struct Record {
        let workspace: Int
        let screen: NSScreen
        /// generation of the admission whose observed minima the retry
        /// ignores for this window.
        let sinceGeneration: UInt64
        /// the admission's own failure, kept for the fallback log line.
        let firstFailure: FrameSizingFailure?
        var phase: Phase
        /// the one attempt has been spent.
        var attempted = false
    }

    // MARK: - seams

    /// Injected so tests can drive the delay. Production hands it to the
    /// main queue.
    var schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, body in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body)
    }
    var retryDelay: TimeInterval = 0.25

    // context probes, all re-checked at fire time
    var workspaceFor: (CGWindowID) -> Int? = { _ in nil }
    var homeScreenForWorkspace: (Int) -> NSScreen? = { _ in nil }
    var isWorkspaceVisible: (Int) -> Bool = { _ in false }
    var isFloating: (CGWindowID) -> Bool = { _ in false }
    /// the live window, or nil when it is gone or its app is not running.
    var liveWindow: (CGWindowID) -> HyprWindow? = { _ in nil }
    /// whether AX can still tell us where the window is.
    var isReadable: (HyprWindow) -> Bool = { $0.frame != nil }
    /// screens are mid-reconfiguration. Tiling anything now builds trees at
    /// keys that are about to move, so the retry waits like the ordinary
    /// retile does.
    var isDisplayTransitionPending: () -> Bool = { false }

    // actions
    /// `bypass` maps each newcomer to the generation whose observed minima
    /// the attempt must ignore for it.
    var attempt: (_ workspace: Int, _ screen: NSScreen,
                  _ bypass: [CGWindowID: UInt64]) -> AttemptResult = { _, _, _ in AttemptResult() }
    var floatInPlace: (HyprWindow, String) -> Void = { _, _ in }
    /// Ask the engine to drop the key's unverified mark. It refuses when a
    /// rollback on that key did not verify, so the answer is its to give.
    var clearUnverified: (Int, NSScreen) -> Void = { _, _ in }

    // MARK: - state

    private var records: [CGWindowID: Record] = [:]
    /// bumped by every cancellation, so a timer already in flight finds a
    /// stale token and does nothing.
    private var token: UInt64 = 0

    /// Windows waiting on a bounded recovery attempt or on the evidence to
    /// finish one. The state dump's `recovery pending=`.
    var pendingWindowIDs: Set<CGWindowID> { Set(records.keys) }

    func phase(of windowID: CGWindowID) -> Phase? { records[windowID]?.phase }

    // MARK: - admission reporting

    /// React to one tiling pass.
    ///
    /// A newcomer that made it into the published tree is finished. One that
    /// did not is stranded, and gets its retry armed unless it is already
    /// pending — the bound is one attempt per window, not one per pass.
    func note(_ result: TilingEngine.AdmissionResult) {
        // the scratchpad layer runs its own recovery and must never enter
        // this path
        guard result.workspace != TilingEngine.scratchpadWorkspace else { return }

        for id in result.publishedIDs where records[id] != nil {
            resolve(id, reason: "tiled")
        }

        let stranded = result.failedInsertedIDs.filter { records[$0] == nil }
        guard !stranded.isEmpty else { return }
        for id in stranded {
            records[id] = Record(workspace: result.workspace, screen: result.screen,
                                 sinceGeneration: result.generation,
                                 firstFailure: result.failure,
                                 phase: .awaitingRetry)
        }
        hyprLog(.notice, .tiling, "admission retry scheduled: ids=\(Self.list(stranded))"
                + " ws\(result.workspace) in \(Int(retryDelay * 1000))ms"
                + " cause=\(Self.text(result.failure))")
        arm()
    }

    // MARK: - cancellation

    /// Drop `windowID` from recovery. Used for the user's own later actions:
    /// a float, a workspace move, a close.
    /// Dropping the record is the cancellation: the armed timer works off
    /// `records`, so an id that is no longer there gets no attempt, and the
    /// windows still waiting keep the timer they were promised.
    func cancel(_ windowID: CGWindowID, reason: String) {
        guard records.removeValue(forKey: windowID) != nil else { return }
        hyprLog(.notice, .tiling, "admission retry cancelled: ids=[\(windowID)] reason=\(reason)")
    }

    /// Drop everything. Used for a stop, a display change, and any later key
    /// press, all of which make the captured context stale.
    func cancelAll(reason: String) {
        guard !records.isEmpty else { return }
        let ids = Set(records.keys)
        records.removeAll()
        token &+= 1
        hyprLog(.notice, .tiling, "admission retry cancelled: ids=\(Self.list(ids)) reason=\(reason)")
    }

    /// The window is gone. Ordinary cleanup, no log of its own — the
    /// lifecycle path already says the window went away.
    func forget(_ windowID: CGWindowID) {
        records.removeValue(forKey: windowID)
    }

    private func resolve(_ windowID: CGWindowID, reason: String) {
        guard records.removeValue(forKey: windowID) != nil else { return }
        hyprLog(.notice, .tiling, "admission recovery resolved: \(windowID) (\(reason))")
    }

    // MARK: - the one retry

    private func arm() {
        token &+= 1
        let armed = token
        schedule(retryDelay) { [weak self] in
            guard let self, self.token == armed else { return }
            self.run(ids: self.records.filter { $0.value.phase == .awaitingRetry }.map(\.key))
        }
    }

    /// A discovery or activation event said something new about `windowID`.
    /// The only thing that moves a window out of `awaitingEvidence`.
    func noteEvidence(for windowID: CGWindowID) {
        guard records[windowID]?.phase == .awaitingEvidence else { return }
        run(ids: [windowID])
    }

    private func run(ids: [CGWindowID]) {
        var byKey: [Int: (screen: NSScreen, bypass: [CGWindowID: UInt64])] = [:]
        for id in ids.sorted() {
            guard let record = records[id] else { continue }
            switch readiness(id, record: record) {
            case .gone:
                forget(id)
            case let .userActed(reason):
                cancel(id, reason: reason)
            case .notYet:
                hold(id)
            case .ready:
                guard !record.attempted else {
                    // its one attempt is spent; the evidence only unblocks
                    // the verdict
                    finish(id, retryFailure: nil)
                    continue
                }
                var entry = byKey[record.workspace] ?? (screen: record.screen, bypass: [:])
                entry.bypass[id] = record.sinceGeneration
                byKey[record.workspace] = entry
            }
        }

        for (workspace, entry) in byKey.sorted(by: { $0.key < $1.key }) {
            for id in entry.bypass.keys { records[id]?.attempted = true }
            let trace = entry.bypass.keys.sorted().map { "\($0):\(entry.bypass[$0]!)" }
                .joined(separator: ",")
            hyprLog(.notice, .tiling, "admission retry attempt: ws\(workspace)"
                    + " bypassMinimaSince=[\(trace)]")
            let result = attempt(workspace, entry.screen, entry.bypass)
            for id in entry.bypass.keys.sorted() {
                if result.placed.contains(id) {
                    resolve(id, reason: "retry tiled it")
                } else {
                    finish(id, retryFailure: result.failure)
                }
            }
        }
    }

    private enum Readiness {
        case ready
        case notYet
        case userActed(String)
        case gone
    }

    private func readiness(_ id: CGWindowID, record: Record) -> Readiness {
        guard let window = liveWindow(id) else { return .gone }
        guard !isDisplayTransitionPending() else { return .notYet }
        guard workspaceFor(id) == record.workspace else { return .userActed("moved workspace") }
        guard homeScreenForWorkspace(record.workspace) == record.screen else {
            return .userActed("screen changed")
        }
        guard !isFloating(id) else { return .userActed("user floated it") }
        guard isWorkspaceVisible(record.workspace) else { return .notYet }
        guard isReadable(window) else { return .notYet }
        return .ready
    }

    /// Park a window that could not be judged. No new timer: the plan is to
    /// wait for evidence, and a renewing timer is how a recovery turns into
    /// a spin.
    private func hold(_ id: CGWindowID) {
        guard records[id]?.phase != .awaitingEvidence else { return }
        records[id]?.phase = .awaitingEvidence
        hyprLog(.notice, .tiling, "admission recovery pending: \(id) not judgeable yet — waiting for evidence")
    }

    /// Second failure. A readable visible newcomer is left floating exactly
    /// where it is; it is not sent anywhere.
    private func finish(_ id: CGWindowID, retryFailure: FrameSizingFailure?) {
        guard let record = records[id] else { return }
        switch readiness(id, record: record) {
        case .gone:
            forget(id)
            return
        case let .userActed(reason):
            cancel(id, reason: reason)
            return
        case .notYet:
            hold(id)
            return
        case .ready:
            break
        }
        guard let window = liveWindow(id) else { forget(id); return }
        let cause = "first=\(Self.text(record.firstFailure)) retry=\(Self.text(retryFailure))"
        hyprLog(.notice, .tiling, "admission recovery fallback: floated \(id) in place"
                + " on ws\(record.workspace) \(cause)")
        floatInPlace(window, cause)
        records.removeValue(forKey: id)
        // the key may be able to speak for itself again now that nothing is
        // waiting on it. the engine decides: it saw every attempt that marked
        // the key, and this recovery only saw two of them.
        clearUnverified(record.workspace, record.screen)
    }

    private static func list(_ ids: Set<CGWindowID>) -> String {
        "[" + ids.sorted().map(String.init).joined(separator: ", ") + "]"
    }

    private static func text(_ failure: FrameSizingFailure?) -> String {
        failure.map { "\($0)" } ?? "none"
    }
}
