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
enum MinSizeProvenance: String {
    case seeded, observed
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
/// Hysteresis on both ends:
/// - Record: only raises, and only on the axis the app refused. A seeded
///   hint is replaced rather than merged, so an axis nothing refused does
///   not inherit a guess and call it evidence.
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

    /// Everything currently remembered, for the state dump.
    var snapshot: [CGWindowID: Entry] { known }

    func entry(for windowID: CGWindowID) -> Entry? { known[windowID] }

    /// Sync this map and the window's mirror. If we already have a recorded
    /// bound, push it onto the window; otherwise pick up a usable AX-seeded
    /// value as our starting estimate, still marked as the hint it is.
    func prime(_ windows: [HyprWindow]) {
        for window in windows {
            if let entry = known[window.windowID] {
                mirror(entry, onto: window)
            } else if let seeded = window.observedMinSize, isUsable(seeded) {
                let entry = Entry(size: seeded, provenance: window.minSizeProvenance)
                known[window.windowID] = entry
                hyprLog(.debug, .lifecycle, "min-size record: wid=\(window.windowID) "
                        + "old=none new=\(Self.text(seeded)) axis=width+height "
                        + "source=\(entry.provenance.rawValue)")
            }
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
    func recordObserved(_ window: HyprWindow,
                        target: CGSize,
                        actual: CGSize,
                        widthConflict: Bool,
                        heightConflict: Bool,
                        phase: FrameSizingPhase) {
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
            return
        }
        let entry = Entry(size: updated, provenance: .observed)
        known[window.windowID] = entry
        mirror(entry, onto: window)
        hyprLog(.debug, .lifecycle, "min-size record: wid=\(window.windowID) "
                + "old=\(old) new=\(Self.text(updated)) target=\(Self.text(target)) "
                + "actual=\(Self.text(actual)) axis=\(axis) phase=\(phase.rawValue) "
                + "source=readback")
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
