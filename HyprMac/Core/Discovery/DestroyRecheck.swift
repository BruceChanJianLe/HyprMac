// Bounded re-poll bookkeeping for destroy notifications whose poll landed
// before the app finished tearing the window down.

import CoreGraphics
import Foundation

/// bounded re-poll after a destroy notification whose poll saw nothing gone.
/// apps tear windows down after the AX element dies, so the 0.2s poll can
/// still enumerate the window; without a follow-up the close is only found
/// by the next mouse-driven poll or the 10s reconcile.
struct DestroyRecheck {
    static let maxAttempts = 3
    static let delay: TimeInterval = 0.35

    /// pid → polls consumed since the destroy notification.
    private(set) var pending: [pid_t: Int] = [:]

    /// each destroy gets a fresh budget; a second close from the same app
    /// must not inherit polls consumed by the first.
    mutating func noteDestroy(pid: pid_t) {
        pending[pid] = 0
    }

    /// Call once per poll. Returns true when another poll should be scheduled.
    mutating func resolve(goneIDs: Set<CGWindowID>,
                          ownersBefore: [CGWindowID: pid_t],
                          runningPIDs: Set<pid_t>) -> Bool {
        for (pid, attempts) in pending {
            let sawClose = goneIDs.contains { ownersBefore[$0] == pid }
            // an app we no longer track windows for has nothing left to lose
            let tracked = ownersBefore.values.contains(pid)
            if sawClose || !runningPIDs.contains(pid) || !tracked {
                pending.removeValue(forKey: pid)
                continue
            }
            let next = attempts + 1
            if next >= Self.maxAttempts {
                pending.removeValue(forKey: pid)
            } else {
                pending[pid] = next
            }
        }
        return !pending.isEmpty
    }
}
