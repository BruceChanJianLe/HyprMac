import Cocoa

struct TiledDragContext: Equatable {
    let workspace: Int
    let physicalDisplayID: CGDirectDisplayID
    let usableFrame: CGRect
    let gap: CGFloat
    let padding: CGFloat
    let maxDepth: Int
    let memberIDs: Set<CGWindowID>
    let floatingIDs: Set<CGWindowID>
    let fingerprint: BSPTree.StructuralFingerprint
}

enum TiledDragMode {
    case insert(targetID: CGWindowID, edge: BSPTargetEdge)
    case swap(targetID: CGWindowID)
    case resize(frame: CGRect)
}

enum TiledDragRejection: Equatable {
    case notTiled
    case floating
    case scratchpad
    case invalidTarget
    case maxDepthExceeded
    case noTarget
}

enum TiledDragFailure: Equatable {
    case preflight(TiledDragRejection)
    case sizing(FrameSizingFailure)
}

struct TiledDragSnapshot {
    let draggedID: CGWindowID
    let sourceTree: BSPTree
    let originalTree: BSPTree
    let context: TiledDragContext
    let originalFrames: [CGWindowID: CGRect]
    let generation: UInt64
}

enum TiledDragCaptureResult {
    case captured(TiledDragSnapshot)
    case ineligible(TiledDragRejection)
    case unknown(FrameSizingFailure)
}

enum TiledDragDropOutcome {
    case ignored
    /// `progress` says what the accepted attempt actually did, so the
    /// engine can apply the same publication gate the tiling trees use.
    case committed(candidate: BSPTree, actualFrames: [CGWindowID: CGRect],
                   progress: FrameSizingProgressReport)
    case rejectedRestored(reason: TiledDragFailure, actualFrames: [CGWindowID: CGRect])
    /// `progress` is nil when nothing knows what was written — provenance
    /// the cache policy cannot narrow with, so it falls back to clearing
    /// every member.
    case degraded(candidateReason: TiledDragFailure?, restorationReason: FrameSizingFailure?,
                  actualFrames: [CGWindowID: CGRect],
                  progress: FrameSizingProgressReport?)
    case superseded
}

struct TiledDragTransaction {
    typealias IOFactory = ([CGWindowID: HyprWindow], @escaping () -> UInt64) -> FrameSizingIO

    let ioFactory: IOFactory

    func capture(pointer: CGPoint, tree: BSPTree, context: TiledDragContext,
                 occludingWindows: [HyprWindow], generation: UInt64,
                 currentContext: @escaping () -> TiledDragContext?,
                 onCapturedFrames: ([CGWindowID: CGRect]) -> Void = { _ in })
        -> TiledDragCaptureResult {
        guard pointer.x.isFinite, pointer.y.isFinite else { return .ineligible(.noTarget) }
        guard currentContext() == context,
              tree.structuralFingerprint() == context.fingerprint else {
            return .unknown(.superseded)
        }
        guard context.workspace != TilingEngine.scratchpadWorkspace else {
            return .ineligible(.scratchpad)
        }
        guard context.floatingIDs.isDisjoint(with: context.memberIDs) else {
            return .ineligible(.floating)
        }
        let tiledWindows = tree.allWindows
        let windows = tiledWindows + occludingWindows
        var seen = Set<CGWindowID>()
        for window in windows where !seen.insert(window.windowID).inserted {
            return .unknown(.duplicateWindowID(window.windowID))
        }
        let tiledIDs = Set(tiledWindows.map(\.windowID))
        guard tiledIDs == context.memberIDs else { return .ineligible(.notTiled) }
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        let io = ioFactory(byID) {
            guard currentContext() == context,
                  tree.structuralFingerprint() == context.fingerprint else {
                return generation &+ 1
            }
            return generation
        }
        let ids = windows.map(\.windowID)
        let captured = FrameSizingAttempt(io: io).captureFrames(windowIDs: ids,
                                                                generation: generation)
        guard case .accepted = captured.verdict,
              captured.actualFrames.count == ids.count else {
            let failure: FrameSizingFailure
            switch captured.verdict {
            case .accepted: failure = .windowUnavailable(ids.first ?? 0)
            case let .rejected(reason), let .unknown(reason): failure = reason
            }
            return .unknown(failure)
        }
        guard currentContext() == context,
              tree.structuralFingerprint() == context.fingerprint else {
            return .unknown(.superseded)
        }
        onCapturedFrames(captured.actualFrames)
        guard currentContext() == context,
              tree.structuralFingerprint() == context.fingerprint else {
            return .unknown(.superseded)
        }
        let tiledHits = tiledWindows.filter {
            captured.actualFrames[$0.windowID]?.contains(pointer) == true
        }
        let occluded = occludingWindows.contains {
            captured.actualFrames[$0.windowID]?.contains(pointer) == true
        }
        guard tiledHits.count == 1, !occluded, let dragged = tiledHits.first else {
            return .ineligible(.noTarget)
        }
        let originals = captured.actualFrames.filter { tiledIDs.contains($0.key) }
        return .captured(TiledDragSnapshot(
            draggedID: dragged.windowID,
            sourceTree: tree,
            originalTree: tree.deepClone(),
            context: context,
            originalFrames: originals,
            generation: generation
        ))
    }

    func capture(draggedID: CGWindowID, tree: BSPTree, context: TiledDragContext,
                 generation: UInt64,
                 currentContext: @escaping () -> TiledDragContext?) -> TiledDragCaptureResult {
        guard currentContext() == context,
              tree.structuralFingerprint() == context.fingerprint else {
            return .unknown(.superseded)
        }
        guard context.workspace != TilingEngine.scratchpadWorkspace else {
            return .ineligible(.scratchpad)
        }
        guard !context.floatingIDs.contains(draggedID) else {
            return .ineligible(.floating)
        }
        let windows = tree.allWindows
        let ids = windows.map(\.windowID)
        var seen = Set<CGWindowID>()
        for id in ids where !seen.insert(id).inserted {
            return .unknown(.duplicateWindowID(id))
        }
        let memberIDs = Set(ids)
        guard memberIDs == context.memberIDs, memberIDs.contains(draggedID) else {
            return .ineligible(.notTiled)
        }
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        let io = ioFactory(byID) {
            guard currentContext() == context,
                  tree.structuralFingerprint() == context.fingerprint else {
                return generation &+ 1
            }
            return generation
        }
        let captured = FrameSizingAttempt(io: io).captureFrames(windowIDs: ids,
                                                                generation: generation)
        guard case .accepted = captured.verdict,
              captured.actualFrames.count == ids.count else {
            let failure: FrameSizingFailure
            switch captured.verdict {
            case .accepted:
                failure = .windowUnavailable(draggedID)
            case let .rejected(reason), let .unknown(reason):
                failure = reason
            }
            return .unknown(failure)
        }
        return .captured(TiledDragSnapshot(
            draggedID: draggedID,
            sourceTree: tree,
            originalTree: tree.deepClone(),
            context: context,
            originalFrames: captured.actualFrames,
            generation: generation
        ))
    }

    func drop(_ snapshot: TiledDragSnapshot, mode: TiledDragMode?,
              currentContext: @escaping () -> TiledDragContext?) -> TiledDragDropOutcome {
        guard isCurrent(snapshot, currentContext: currentContext) else { return .superseded }
        let windows = snapshot.sourceTree.allWindows
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        let io = ioFactory(byID) {
            isCurrent(snapshot, currentContext: currentContext)
                ? snapshot.generation : snapshot.generation &+ 1
        }
        let attempt = FrameSizingAttempt(io: io)

        guard let mode else {
            return restore(snapshot, reason: .preflight(.noTarget), attempt: attempt)
        }
        let targetID: CGWindowID?
        switch mode {
        case let .insert(id, _), let .swap(id): targetID = id
        case .resize: targetID = nil
        }
        guard targetID.map({ $0 != snapshot.draggedID
            && snapshot.context.memberIDs.contains($0) }) ?? true else {
            return restore(snapshot, reason: .preflight(.invalidTarget), attempt: attempt)
        }

        let candidate: BSPTree?
        switch mode {
        case let .insert(targetID, edge):
            candidate = snapshot.originalTree.candidateTree(
                draggedID: snapshot.draggedID, targetID: targetID,
                edge: edge, maxDepth: snapshot.context.maxDepth)
        case let .swap(targetID):
            let clone = snapshot.originalTree.deepClone()
            guard let dragged = clone.allWindows.first(where: { $0.windowID == snapshot.draggedID }),
                  let target = clone.allWindows.first(where: { $0.windowID == targetID }) else {
                return restore(snapshot, reason: .preflight(.invalidTarget), attempt: attempt)
            }
            clone.swap(dragged, target)
            candidate = clone
        case let .resize(frame):
            let clone = snapshot.originalTree.deepClone()
            guard let dragged = clone.allWindows.first(where: {
                $0.windowID == snapshot.draggedID
            }) else {
                return restore(snapshot, reason: .preflight(.invalidTarget), attempt: attempt)
            }
            clone.applyResizeDelta(for: dragged, newFrame: frame,
                                   in: snapshot.context.usableFrame,
                                   gap: snapshot.context.gap,
                                   padding: snapshot.context.padding)
            candidate = clone
        }
        guard let candidate else {
            return restore(snapshot, reason: .preflight(.maxDepthExceeded), attempt: attempt)
        }
        guard candidate.root.allLeavesRightToLeft().allSatisfy({
            $0.depth <= snapshot.context.maxDepth
        }) else {
            return restore(snapshot, reason: .preflight(.maxDepthExceeded), attempt: attempt)
        }
        let layouts = candidate.layout(in: snapshot.context.usableFrame,
                                       gap: snapshot.context.gap,
                                       padding: snapshot.context.padding)
        guard valid(layouts, context: snapshot.context, attempt: attempt) else {
            return restore(snapshot, reason: .preflight(.invalidTarget), attempt: attempt)
        }
        guard isCurrent(snapshot, currentContext: currentContext) else { return .superseded }
        let transaction = FrameSizingTransaction(attempt: attempt)
        let result = transaction.apply(
            targets: layouts.map { .init(windowID: $0.0.windowID, frame: $0.1) },
            originalFrames: snapshot.originalFrames,
            usableFrame: snapshot.context.usableFrame,
            gap: snapshot.context.gap,
            generation: snapshot.generation
        )
        switch result.outcome {
        case let .accepted(actualFrames):
            guard isCurrent(snapshot, currentContext: currentContext) else { return .superseded }
            return .committed(candidate: candidate, actualFrames: actualFrames,
                              progress: result.progress)
        case let .rejectedRestored(reason, actualFrames):
            return .rejectedRestored(reason: .sizing(reason), actualFrames: actualFrames)
        case let .degraded(candidateReason, restorationReason, actualFrames):
            if candidateReason == .superseded, restorationReason == nil { return .superseded }
            return .degraded(candidateReason: .sizing(candidateReason),
                             restorationReason: restorationReason,
                             actualFrames: actualFrames,
                             progress: result.progress)
        }
    }

    func dropRelease(_ snapshot: TiledDragSnapshot, mode: TiledDragMode?,
                     currentContext: @escaping () -> TiledDragContext?)
        -> TiledDragDropOutcome {
        guard isCurrent(snapshot, currentContext: currentContext) else { return .superseded }
        let windows = snapshot.sourceTree.allWindows
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        let io = ioFactory(byID) {
            isCurrent(snapshot, currentContext: currentContext)
                ? snapshot.generation : snapshot.generation &+ 1
        }
        let attempt = FrameSizingAttempt(io: io)
        let classified = attempt.captureFrames(windowIDs: [snapshot.draggedID],
                                               generation: snapshot.generation)
        guard case .accepted = classified.verdict,
              let frame = classified.actualFrames[snapshot.draggedID] else {
            let failure: FrameSizingFailure
            switch classified.verdict {
            case .accepted: failure = .windowUnavailable(snapshot.draggedID)
            case let .rejected(reason), let .unknown(reason): failure = reason
            }
            if failure == .superseded { return .superseded }
            return restore(snapshot, reason: .sizing(failure), attempt: attempt)
        }
        guard isCurrent(snapshot, currentContext: currentContext) else { return .superseded }
        let original = snapshot.originalFrames[snapshot.draggedID]
        let resized = original.map {
            abs(frame.size.width - $0.size.width) > 20
                || abs(frame.size.height - $0.size.height) > 20
        } ?? false
        if !resized, let original {
            let tolerance = FrameSizingConfiguration()
            let unchanged = abs(frame.minX - original.minX) <= tolerance.positionTolerance
                && abs(frame.minY - original.minY) <= tolerance.positionTolerance
                && abs(frame.size.width - original.size.width) <= tolerance.sizeTolerance
                && abs(frame.size.height - original.size.height) <= tolerance.sizeTolerance
            if unchanged { return .ignored }
        }
        let outcome = drop(snapshot, mode: resized ? .resize(frame: frame) : mode,
                           currentContext: currentContext)
        guard isCurrent(snapshot, currentContext: currentContext) else { return .superseded }
        return outcome
    }

    private func isCurrent(_ snapshot: TiledDragSnapshot,
                           currentContext: () -> TiledDragContext?) -> Bool {
        currentContext() == snapshot.context
            && snapshot.sourceTree.structuralFingerprint() == snapshot.context.fingerprint
    }

    private func restore(_ snapshot: TiledDragSnapshot, reason: TiledDragFailure,
                         attempt: FrameSizingAttempt) -> TiledDragDropOutcome {
        let result = FrameSizingTransaction(attempt: attempt).restore(
            originalFrames: snapshot.originalFrames,
            usableFrame: snapshot.context.usableFrame,
            gap: snapshot.context.gap,
            generation: snapshot.generation
        )
        switch result.verdict {
        case .accepted:
            return .rejectedRestored(reason: reason, actualFrames: result.actualFrames)
        case let .rejected(failure), let .unknown(failure):
            if failure == .superseded { return .superseded }
            // nothing ran a candidate here, so the only writes on record
            // are the rollback's own
            return .degraded(candidateReason: reason,
                             restorationReason: failure,
                             actualFrames: result.actualFrames,
                             progress: FrameSizingProgressReport(
                                restoration: result.progress,
                                restorationOverlaps: result.overlaps))
        }
    }

    private func valid(_ layouts: [(HyprWindow, CGRect)], context: TiledDragContext,
                       attempt: FrameSizingAttempt) -> Bool {
        guard layouts.count == context.memberIDs.count,
              Set(layouts.map { $0.0.windowID }) == context.memberIDs else { return false }
        for (_, frame) in layouts {
            guard frame.origin.x.isFinite, frame.origin.y.isFinite,
                  frame.size.width.isFinite, frame.size.height.isFinite,
                  frame.size.width > 0, frame.size.height > 0 else { return false }
        }
        let targets = layouts.map {
            FrameSizingAttempt.Target(windowID: $0.0.windowID, frame: $0.1)
        }
        let frames = Dictionary(uniqueKeysWithValues: layouts.map { ($0.0.windowID, $0.1) })
        return attempt.validateFrames(targets: targets, actualFrames: frames,
                                      usableFrame: context.usableFrame,
                                      gap: context.gap).verdict == .accepted
    }
}
