// Coordinates verified tiled-drag capture, deferred release, cache updates,
// and completion reporting.

import Cocoa

struct MouseDragLifecycleState {
    var buttonDown = false
    var sawDragEvent = false
    var preDragFocusedID: CGWindowID = 0

    mutating func resetForStop() {
        buttonDown = false
        sawDragEvent = false
        preDragFocusedID = 0
    }
}

struct TiledDragRelease: Equatable {
    let pointer: CGPoint
    let optionDown: Bool
    let sawDragEvent: Bool
}

struct TiledDragPressResolver {
    static func resolve(pointer: CGPoint,
                        tiledFrames: [CGWindowID: CGRect],
                        occluderFrames: [CGWindowID: CGRect]) -> CGWindowID? {
        func contains(_ frame: CGRect) -> Bool {
            pointer.x >= frame.minX && pointer.x <= frame.maxX
                && pointer.y >= frame.minY && pointer.y <= frame.maxY
        }
        guard !occluderFrames.values.contains(where: contains) else { return nil }
        let matches = tiledFrames.compactMap { id, frame in contains(frame) ? id : nil }
        return matches.count == 1 ? matches[0] : nil
    }
}

extension TiledDragTargetResolver {
    static func resolve(pointer: CGPoint, snapshot: TiledDragSnapshot) -> TiledDragTarget? {
        resolve(pointer: pointer, draggedID: snapshot.draggedID,
                intendedSlots: snapshot.originalFrames)
    }
}

struct TiledDragCacheUpdate {
    static func applying(_ outcome: TiledDragDropOutcome,
                         affectedIDs: Set<CGWindowID>,
                         to existing: [CGWindowID: CGRect]) -> [CGWindowID: CGRect] {
        var updated = existing
        switch outcome {
        case let .committed(_, actualFrames), let .rejectedRestored(_, actualFrames):
            for id in affectedIDs {
                if let frame = actualFrames[id] {
                    updated[id] = frame
                } else {
                    updated.removeValue(forKey: id)
                }
            }
        case .degraded:
            for id in affectedIDs { updated.removeValue(forKey: id) }
        case .superseded, .ignored:
            break
        }
        return updated
    }
}

struct TiledDragCompletion {
    let snapshot: TiledDragSnapshot
    let outcome: TiledDragDropOutcome
}

final class TiledDragSessionCoordinator {
    typealias Capture = (CGPoint) -> TiledDragCaptureResult
    typealias Apply = (TiledDragSnapshot, TiledDragMode?) -> TiledDragDropOutcome
    typealias ResolveTarget = (CGPoint, TiledDragSnapshot) -> TiledDragTarget?
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void
    typealias Report = (TiledDragCompletion) -> Void
    typealias CaptureFailureReport = (TiledDragCaptureResult) -> Void

    private(set) var isFinishingDrag = false
    private let capture: Capture
    private let apply: Apply
    private let resolveTarget: ResolveTarget
    private let schedule: Schedule
    private let report: Report
    private let captureFailureReport: CaptureFailureReport
    private var pressEpoch: UInt64 = 0
    private var snapshot: TiledDragSnapshot?
    private var captureFailure: TiledDragCaptureResult?

    init(capture: @escaping Capture,
         apply: @escaping Apply,
         resolveTarget: @escaping ResolveTarget,
         schedule: @escaping Schedule,
         report: @escaping Report,
         captureFailureReport: @escaping CaptureFailureReport = { _ in }) {
        self.capture = capture
        self.apply = apply
        self.resolveTarget = resolveTarget
        self.schedule = schedule
        self.report = report
        self.captureFailureReport = captureFailureReport
    }

    func mouseDown(at pointer: CGPoint) {
        pressEpoch &+= 1
        let epoch = pressEpoch
        isFinishingDrag = false
        snapshot = nil
        captureFailure = nil
        let result = capture(pointer)
        guard pressEpoch == epoch else { return }
        if case let .captured(captured) = result {
            snapshot = captured
            captureFailure = nil
        } else {
            snapshot = nil
            if case .unknown = result {
                captureFailure = result
            } else {
                captureFailure = nil
            }
        }
    }

    func mouseUp(_ release: TiledDragRelease) {
        guard release.sawDragEvent else {
            pressEpoch &+= 1
            self.snapshot = nil
            captureFailure = nil
            isFinishingDrag = false
            return
        }
        guard let snapshot else {
            pressEpoch &+= 1
            let epoch = pressEpoch
            if let captureFailure { captureFailureReport(captureFailure) }
            guard pressEpoch == epoch else { return }
            self.captureFailure = nil
            isFinishingDrag = false
            return
        }
        let epoch = pressEpoch
        isFinishingDrag = true
        schedule(0.1) { [weak self] in
            guard let self, self.pressEpoch == epoch else { return }
            let mode: TiledDragMode?
            if let target = self.resolveTarget(release.pointer, snapshot) {
                mode = release.optionDown
                    ? .swap(targetID: target.windowID)
                    : .insert(targetID: target.windowID, edge: target.edge)
            } else {
                mode = nil
            }
            let outcome = self.apply(snapshot, mode)
            guard self.pressEpoch == epoch else { return }
            self.report(TiledDragCompletion(snapshot: snapshot, outcome: outcome))
            guard self.pressEpoch == epoch else { return }
            self.snapshot = nil
            self.captureFailure = nil
            self.isFinishingDrag = false
        }
    }

    func cancel() {
        pressEpoch &+= 1
        snapshot = nil
        captureFailure = nil
        isFinishingDrag = false
    }
}

final class TiledDragHandler {
    typealias Capture = (CGPoint, @escaping ([CGWindowID: CGRect]) -> Void) -> TiledDragCaptureResult
    typealias CacheRead = () -> [CGWindowID: CGRect]
    typealias CacheWrite = ([CGWindowID: CGRect]) -> Void
    typealias Completion = (TiledDragCompletion) -> Void

    private let coordinator: TiledDragSessionCoordinator
    var isFinishingDrag: Bool { coordinator.isFinishingDrag }

    init(capture: @escaping Capture,
         drop: @escaping TiledDragSessionCoordinator.Apply,
         resolveTarget: @escaping TiledDragSessionCoordinator.ResolveTarget,
         schedule: @escaping TiledDragSessionCoordinator.Schedule,
         capturedFrames: @escaping ([CGWindowID: CGRect]) -> Void,
         readCache: @escaping CacheRead,
         writeCache: @escaping CacheWrite,
         completion: @escaping Completion,
         captureFailure: @escaping TiledDragSessionCoordinator.CaptureFailureReport) {
        coordinator = TiledDragSessionCoordinator(
            capture: { point in capture(point, capturedFrames) },
            apply: drop,
            resolveTarget: resolveTarget,
            schedule: schedule,
            report: { result in
                if case .ignored = result.outcome { return }
                if case .superseded = result.outcome {
                    completion(result)
                    return
                }
                let updated = TiledDragCacheUpdate.applying(
                    result.outcome,
                    affectedIDs: result.snapshot.context.memberIDs,
                    to: readCache()
                )
                writeCache(updated)
                completion(result)
            },
            captureFailureReport: captureFailure
        )
    }

    func handleMouseDown(at pointer: CGPoint) {
        coordinator.mouseDown(at: pointer)
    }

    func handleMouseUp(_ release: TiledDragRelease) {
        coordinator.mouseUp(release)
    }

    func cancel() {
        coordinator.cancel()
    }
}
