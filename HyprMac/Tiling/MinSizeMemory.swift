// Per-window min-size bookkeeping for the tiling subsystem. macOS apps
// do not expose reliable `AXMinimumSize`; this class learns the actual
// floor from `FrameReadbackPoller`'s guarded readback evidence and
// remembers it for subsequent layout decisions.

import Cocoa

/// Where a remembered minimum came from.
///
/// `seeded` is a hint: `AXMinimumSize` or a per-bundle-id guess. Nothing
/// has refused a smaller frame, so it is a starting estimate only.
/// `observed` is a bound the app actually refused to shrink below, on the
/// axis it refused, read back at the origin it was told to sit at.
/// `appHint` is another window of the same app's `observed` bound, carried
/// over so a second Outlook window does not have to prove the same floor
/// with its own visible resize. It is stronger than a guess and weaker than
/// evidence: fit checks honour it, and nothing that keys on `observed`
/// — the minima bypass, the refusal diagnostics' `learned` source — does.
enum MinSizeProvenance: String {
    case seeded, observed, appHint
}

/// Per-window min-size memory.
///
/// macOS apps with hard minimums (Spotify, Messages, Xcode) refuse to
/// shrink past a UI-state-dependent floor that AX does not surface up
/// front. When a readback survives the learning guards in
/// `FrameReadbackPoller`, the observed size becomes the new known min
/// until a later layout witnesses an even tighter accepted resize and
/// lowers the bound.
///
/// Per-axis evidence is kept per axis. Zero on an axis means nothing has
/// refused anything there, and a fit check reads it as no constraint.
///
/// A window with no entry of its own starts from its app's hint when one
/// of the app's other windows has refused something. Hints live in memory
/// only and are keyed by bundle id; nothing persists across a restart.
///
/// Hysteresis on both ends:
/// - Record: only raises, and only on the axis the app refused. A seeded
///   hint or an app hint is replaced rather than merged, so an axis nothing
///   refused does not inherit a guess and call it evidence.
/// - Lower: requires an accepted size at least
///   `lowerMinSizeAcceptedDeltaPx` below the current bound — sub-pixel
///   accepts cannot ratchet the floor down.
///
/// The memory is mirrored back onto each `HyprWindow.observedMinSize` and
/// `HyprWindow.minSizeProvenance` so other subsystems (drag-swap fit
/// checks) see consistent values.
class MinSizeMemory {
    /// One remembered minimum and what kind of evidence produced it.
    struct Entry: Equatable {
        var size: CGSize
        var provenance: MinSizeProvenance
    }

    private var known: [CGWindowID: Entry] = [:]
    /// Per-axis max of every `observed` bound this app's windows have
    /// produced, keyed by bundle id. Memory only: a restart starts over,
    /// because a floor depends on the UI state the window was in.
    private var appHints: [String: CGSize] = [:]

    /// Everything currently remembered, for the state dump.
    var snapshot: [CGWindowID: Entry] { known }

    func entry(for windowID: CGWindowID) -> Entry? { known[windowID] }

    /// Sync this map and the window's mirror. If we already have a recorded
    /// bound, push it onto the window; otherwise take the app's hint if its
    /// siblings have produced one, and failing that a usable AX-seeded value
    /// as our starting estimate. Both are marked as the hints they are.
    ///
    /// The app's hint outranks the AX seed: one of this app's own windows
    /// actually refused that size, while the seed is a number the app
    /// published without being asked.
    func prime(_ windows: [HyprWindow]) {
        for window in windows {
            if let entry = known[window.windowID] {
                mirror(entry, onto: window)
                continue
            }
            var candidate: Entry?
            if let bundleID = window.bundleID, let hint = appHints[bundleID], isUsable(hint) {
                candidate = Entry(size: hint, provenance: .appHint)
            } else if let seeded = window.observedMinSize, isUsable(seeded) {
                candidate = Entry(size: seeded, provenance: window.minSizeProvenance)
            }
            guard let entry = candidate else { continue }
            known[window.windowID] = entry
            mirror(entry, onto: window)
            hyprLog(.debug, .lifecycle, "min-size record: wid=\(window.windowID) "
                    + "old=none new=\(Self.text(entry.size)) axis=width+height "
                    + "source=\(entry.provenance.rawValue)")
        }
    }

    func forget(windowID: CGWindowID) {
        known.removeValue(forKey: windowID)
    }

    func minimumSize(for window: HyprWindow?) -> CGSize {
        guard let window else { return .zero }
        return known[window.windowID]?.size ?? window.observedMinSize ?? .zero
    }

    /// Record a settled min-size conflict that passed `FrameReadbackPoller`'s
    /// learning guards. Raises the bound on whichever axis the app refused;
    /// never lowers from here.
    ///
    /// A seeded hint is not a floor, so real evidence replaces it instead of
    /// merging with it: the axis this readback did not refuse goes back to
    /// unknown rather than keeping a guess under an `observed` label.
    ///
    /// - Returns: `true` when an entry was written, so the caller can stamp
    ///   when the evidence arrived.
    @discardableResult
    func recordObserved(_ window: HyprWindow,
                        target: CGSize,
                        actual: CGSize,
                        widthConflict: Bool,
                        heightConflict: Bool,
                        phase: FrameSizingPhase) -> Bool {
        let existing = known[window.windowID]
        let base = existing?.provenance == .observed ? (existing?.size ?? .zero) : CGSize.zero
        let updated = CGSize(
            width: widthConflict ? max(base.width, actual.width) : base.width,
            height: heightConflict ? max(base.height, actual.height) : base.height
        )
        let axis = FrameReadbackPoller.axis(width: widthConflict, height: heightConflict)
        let old = existing.map { "\(Self.text($0.size)) source=\($0.provenance.rawValue)" } ?? "none"
        guard isUsable(updated) else {
            hyprLog(.debug, .lifecycle, "min-size record: wid=\(window.windowID) "
                    + "old=\(old) target=\(Self.text(target)) actual=\(Self.text(actual)) "
                    + "axis=\(axis) phase=\(phase.rawValue) source=readback refused=unusable")
            return false
        }
        let entry = Entry(size: updated, provenance: .observed)
        known[window.windowID] = entry
        mirror(entry, onto: window)
        rememberAppHint(for: window, entry.size)
        hyprLog(.debug, .lifecycle, "min-size record: wid=\(window.windowID) "
                + "old=\(old) new=\(Self.text(updated)) target=\(Self.text(target)) "
                + "actual=\(Self.text(actual)) axis=\(axis) phase=\(phase.rawValue) "
                + "source=readback")
        return true
    }

    /// An accepted readback at least `lowerMinSizeAcceptedDeltaPx` smaller than
    /// the recorded bound unlocks a new (lower) bound. without this, a
    /// previously-recorded high mark would never relax even after the app
    /// learns to shrink (e.g., after a window-mode toggle in Xcode).
    ///
    /// Lowering relaxes an estimate, it does not establish a constraint, so
    /// the entry keeps the provenance it had. An accepted size equal to the
    /// bound changes nothing: a window that only ever fits its whole slot
    /// accepts its whole slot, which is not evidence it can be smaller.
    func lowerIfAccepted(_ window: HyprWindow, actual: CGSize) {
        guard let existing = known[window.windowID] else { return }
        let knownSize = existing.size
        guard actual.width < knownSize.width - TilingConfig.lowerMinSizeAcceptedDeltaPx
            || actual.height < knownSize.height - TilingConfig.lowerMinSizeAcceptedDeltaPx else { return }
        let updated = CGSize(width: min(knownSize.width, actual.width),
                             height: min(knownSize.height, actual.height))
        let axis = FrameReadbackPoller.axis(width: updated.width < knownSize.width,
                                            height: updated.height < knownSize.height)
        if isUsable(updated) {
            let entry = Entry(size: updated, provenance: existing.provenance)
            known[window.windowID] = entry
            mirror(entry, onto: window)
            hyprLog(.debug, .lifecycle, "min-size lower: wid=\(window.windowID) "
                    + "old=\(Self.text(knownSize)) new=\(Self.text(updated)) "
                    + "actual=\(Self.text(actual)) axis=\(axis) "
                    + "source=accepted was=\(existing.provenance.rawValue)")
        } else {
            known.removeValue(forKey: window.windowID)
            window.observedMinSize = nil
            window.minSizeProvenance = .seeded
            hyprLog(.debug, .lifecycle, "min-size lower: wid=\(window.windowID) "
                    + "old=\(Self.text(knownSize)) new=none "
                    + "actual=\(Self.text(actual)) axis=\(axis) "
                    + "source=accepted was=\(existing.provenance.rawValue)")
        }
    }

    /// Raise the owning app's hint to cover what this window refused.
    ///
    /// Only real evidence feeds the hint — a hint never feeds itself, so an
    /// `appHint` entry cannot ratchet the app's floor upward through window
    /// after window. Per-axis max, because one window may have refused on
    /// width and another on height.
    private func rememberAppHint(for window: HyprWindow, _ size: CGSize) {
        guard let bundleID = window.bundleID else { return }
        let existing = appHints[bundleID] ?? .zero
        let raised = CGSize(width: max(existing.width, size.width),
                            height: max(existing.height, size.height))
        guard raised != existing else { return }
        appHints[bundleID] = raised
        hyprLog(.debug, .lifecycle, "min-size app hint: bundle=\(bundleID) "
                + "old=\(existing == .zero ? "none" : Self.text(existing)) "
                + "new=\(Self.text(raised)) from=\(window.windowID)")
    }

    private func mirror(_ entry: Entry, onto window: HyprWindow) {
        window.observedMinSize = entry.size
        window.minSizeProvenance = entry.provenance
    }

    private static func text(_ size: CGSize) -> String {
        String(format: "%gx%g", Double(size.width), Double(size.height))
    }

    /// Reject NaN, infinities, fully-zero sizes, and bogus AX sentinels.
    private func isUsable(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && (size.width > 0 || size.height > 0)
            && size.width < TilingConfig.usableMinSizeMaxPx
            && size.height < TilingConfig.usableMinSizeMaxPx
    }
}
