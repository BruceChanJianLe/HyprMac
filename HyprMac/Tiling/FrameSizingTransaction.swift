import Cocoa

enum FrameSizingFailure: Equatable {
    indirect case cleanupFailed(CGWindowID, primary: FrameSizingFailure?, error: AXError)
    case writeFailed(CGWindowID, AXError)
    case readFailed(CGWindowID, AXError)
    case deadlineExceeded
    case attemptsExhausted
    case geometryMismatch(CGWindowID)
    case outsideUsableFrame(CGWindowID)
    case overlap(CGWindowID, CGWindowID)
    case gapViolation(CGWindowID, CGWindowID)
    case windowUnavailable(CGWindowID)
    case duplicateWindowID(CGWindowID)
    case invalidFrame(CGWindowID)
    case superseded
}

struct FrameSizingIO {
    let setMessagingTimeout: (CGWindowID, TimeInterval) -> AXError
    let writeSize: (CGWindowID, CGSize, TimeInterval) -> AXError
    let writePosition: (CGWindowID, CGPoint, TimeInterval) -> AXError
    let readPosition: (CGWindowID, TimeInterval) -> (AXError, CGPoint?)
    let readSize: (CGWindowID, TimeInterval) -> (AXError, CGSize?)
    let now: () -> TimeInterval
    let sleep: (TimeInterval) -> Void
    let currentGeneration: () -> UInt64
    var beginFrameWrite: (CGWindowID, TimeInterval, () -> FrameSizingFailure?) -> AXFrameWriteBatch.BeginResult = {
        windowID, _, _ in .ready(.noop(windowID: windowID))
    }
    var endFrameWrite: (AXFrameWriteBatch.Token, TimeInterval, () -> FrameSizingFailure?) -> AXFrameWriteBatch.EndResult = {
        _, _, _ in .restored
    }
}

extension FrameSizingIO {
    static func accessibility(windows: [CGWindowID: HyprWindow],
                              currentGeneration: @escaping () -> UInt64) -> FrameSizingIO {
        FrameSizingIO(
            setMessagingTimeout: { id, timeout in
                windows[id]?.setMessagingTimeout(timeout) ?? .invalidUIElement
            },
            writeSize: { id, size, _ in windows[id]?.writeSize(size) ?? .invalidUIElement },
            writePosition: { id, position, _ in windows[id]?.writePosition(position) ?? .invalidUIElement },
            readPosition: { id, _ in windows[id]?.readPosition() ?? (.invalidUIElement, nil) },
            readSize: { id, _ in windows[id]?.readSize() ?? (.invalidUIElement, nil) },
            now: { ProcessInfo.processInfo.systemUptime },
            sleep: { Thread.sleep(forTimeInterval: $0) },
            currentGeneration: currentGeneration,
            beginFrameWrite: { id, timeout, checkpoint in
                windows[id]?.beginFrameWrite(timeout: timeout, checkpoint: checkpoint)
                    ?? .failed(.invalidUIElement)
            },
            endFrameWrite: { token, timeout, checkpoint in
                AXFrameWriteBatch.accessibility.end(token, timeout: timeout,
                                                    checkpoint: checkpoint)
            }
        )
    }
}

struct FrameSizingConfiguration {
    var deadline: TimeInterval = 0.36
    var pollInterval: TimeInterval = 0.03
    var maximumAttempts: Int = 12
    var positionTolerance: CGFloat = 1
    var sizeTolerance: CGFloat = 1
    // cell-quantizing apps (terminals) round a target to whole character
    // cells, in either direction. restoration pins both back to sizeTolerance.
    var sizeOvershootTolerance: CGFloat = TilingConfig.frameToleranceXPx
    var sizeUndershootTolerance: CGFloat = TilingConfig.frameToleranceXPx
    var stableTolerance: CGFloat = 0.01
    var requiredStableSamples: Int = 2
    var minimumMismatchSettle: TimeInterval = 0.24
    var perCallTimeout: TimeInterval = 0.1
}

struct FrameSizingAttempt {
    struct Target: Equatable {
        let windowID: CGWindowID
        let frame: CGRect
    }

    enum Verdict: Equatable {
        case accepted
        case rejected(FrameSizingFailure)
        case unknown(FrameSizingFailure)
    }

    struct Result: Equatable {
        let verdict: Verdict
        let actualFrames: [CGWindowID: CGRect]
    }

    let io: FrameSizingIO
    var configuration = FrameSizingConfiguration()

    func captureFrames(windowIDs: [CGWindowID], generation: UInt64) -> Result {
        let started = io.now()
        var frames: [CGWindowID: CGRect] = [:]
        guard io.currentGeneration() == generation else {
            return Result(verdict: .unknown(.superseded), actualFrames: frames)
        }
        var seen = Set<CGWindowID>()
        for windowID in windowIDs where !seen.insert(windowID).inserted {
            return Result(verdict: .unknown(.duplicateWindowID(windowID)), actualFrames: frames)
        }
        for windowID in windowIDs.sorted() {
            guard io.currentGeneration() == generation else {
                return Result(verdict: .unknown(.superseded), actualFrames: frames)
            }
            guard io.now() - started < configuration.deadline else {
                return Result(verdict: .unknown(.deadlineExceeded), actualFrames: frames)
            }
            let timeoutError = io.setMessagingTimeout(windowID, configuration.perCallTimeout)
            guard io.currentGeneration() == generation else {
                return Result(verdict: .unknown(.superseded), actualFrames: frames)
            }
            guard io.now() - started < configuration.deadline else {
                return Result(verdict: .unknown(.deadlineExceeded), actualFrames: frames)
            }
            guard timeoutError == .success else {
                let failure: FrameSizingFailure = timeoutError == .invalidUIElement
                    ? .windowUnavailable(windowID) : .readFailed(windowID, timeoutError)
                return Result(verdict: .unknown(failure), actualFrames: frames)
            }
            let (positionError, position) = io.readPosition(windowID, configuration.perCallTimeout)
            guard io.currentGeneration() == generation else {
                return Result(verdict: .unknown(.superseded), actualFrames: frames)
            }
            guard io.now() - started < configuration.deadline else {
                return Result(verdict: .unknown(.deadlineExceeded), actualFrames: frames)
            }
            guard positionError == .success, let position else {
                let failure: FrameSizingFailure = positionError == .invalidUIElement
                    ? .windowUnavailable(windowID) : .readFailed(windowID, positionError)
                return Result(verdict: .unknown(failure), actualFrames: frames)
            }
            let sizeTimeoutError = io.setMessagingTimeout(windowID, configuration.perCallTimeout)
            guard io.currentGeneration() == generation else {
                return Result(verdict: .unknown(.superseded), actualFrames: frames)
            }
            guard io.now() - started < configuration.deadline else {
                return Result(verdict: .unknown(.deadlineExceeded), actualFrames: frames)
            }
            guard sizeTimeoutError == .success else {
                let failure: FrameSizingFailure = sizeTimeoutError == .invalidUIElement
                    ? .windowUnavailable(windowID) : .readFailed(windowID, sizeTimeoutError)
                return Result(verdict: .unknown(failure), actualFrames: frames)
            }
            let (sizeError, size) = io.readSize(windowID, configuration.perCallTimeout)
            guard io.currentGeneration() == generation else {
                return Result(verdict: .unknown(.superseded), actualFrames: frames)
            }
            guard io.now() - started < configuration.deadline else {
                return Result(verdict: .unknown(.deadlineExceeded), actualFrames: frames)
            }
            guard sizeError == .success, let size else {
                let failure: FrameSizingFailure = sizeError == .invalidUIElement
                    ? .windowUnavailable(windowID) : .readFailed(windowID, sizeError)
                return Result(verdict: .unknown(failure), actualFrames: frames)
            }
            let frame = CGRect(origin: position, size: size)
            guard valid(frame) else {
                return Result(verdict: .unknown(.invalidFrame(windowID)), actualFrames: frames)
            }
            frames[windowID] = frame
        }
        return Result(verdict: .accepted, actualFrames: frames)
    }

    func apply(targets: [Target], usableFrame: CGRect, gap: CGFloat,
               generation: UInt64) -> Result {
        guard io.currentGeneration() == generation else {
            return Result(verdict: .unknown(.superseded), actualFrames: [:])
        }
        guard !targets.isEmpty else {
            return Result(verdict: .accepted, actualFrames: [:])
        }
        var seen = Set<CGWindowID>()
        for target in targets {
            guard seen.insert(target.windowID).inserted else {
                return Result(verdict: .rejected(.duplicateWindowID(target.windowID)), actualFrames: [:])
            }
            let frame = target.frame
            guard frame.origin.x.isFinite, frame.origin.y.isFinite,
                  frame.size.width.isFinite, frame.size.height.isFinite,
                  frame.size.width > 0, frame.size.height > 0 else {
                return Result(verdict: .rejected(.invalidFrame(target.windowID)), actualFrames: [:])
            }
        }
        let started = io.now()
        var actualFrames: [CGWindowID: CGRect] = [:]

        func interruption() -> FrameSizingFailure? {
            if io.currentGeneration() != generation { return .superseded }
            if io.now() - started >= configuration.deadline { return .deadlineExceeded }
            return nil
        }

        for target in targets {
            if let result = write(target, actualFrames: actualFrames,
                                  checkpoint: interruption) { return result }
        }

        var stableAnchors: [CGWindowID: CGRect] = [:]
        var stableCounts: [CGWindowID: Int] = [:]
        for attemptIndex in 0..<configuration.maximumAttempts {
            for target in targets {
                if let result = read(target, actualFrames: &actualFrames,
                                     checkpoint: interruption) { return result }
                guard let frame = actualFrames[target.windowID] else {
                    return Result(verdict: .unknown(.windowUnavailable(target.windowID)),
                                  actualFrames: actualFrames)
                }
                if let anchor = stableAnchors[target.windowID], stable(frame, anchor) {
                    stableCounts[target.windowID, default: 1] += 1
                } else {
                    stableAnchors[target.windowID] = frame
                    stableCounts[target.windowID] = 1
                }
            }
            if targets.allSatisfy({ stableCounts[$0.windowID, default: 0] >= configuration.requiredStableSamples }) {
                let allOnTarget = targets.allSatisfy { target in
                    actualFrames[target.windowID].map { matches($0, target.frame) } ?? false
                }
                if allOnTarget || io.now() - started >= configuration.minimumMismatchSettle {
                    return validateFrames(targets: targets, actualFrames: actualFrames,
                                          usableFrame: usableFrame, gap: gap)
                }
            }
            if attemptIndex + 1 < configuration.maximumAttempts {
                io.sleep(configuration.pollInterval)
                if let failure = interruption() {
                    return Result(verdict: .unknown(failure), actualFrames: actualFrames)
                }
            }
        }
        return Result(verdict: .unknown(.attemptsExhausted), actualFrames: actualFrames)
    }

    private func prepare(_ windowID: CGWindowID,
                         checkpoint: () -> FrameSizingFailure?) -> FrameSizingFailure? {
        let error = io.setMessagingTimeout(windowID, configuration.perCallTimeout)
        if let failure = checkpoint() { return failure }
        if error == .invalidUIElement { return .windowUnavailable(windowID) }
        return error == .success ? nil : .writeFailed(windowID, error)
    }

    private func prepareRead(_ windowID: CGWindowID,
                             checkpoint: () -> FrameSizingFailure?) -> FrameSizingFailure? {
        guard let failure = prepare(windowID, checkpoint: checkpoint) else { return nil }
        if case let .writeFailed(id, error) = failure { return .readFailed(id, error) }
        return failure
    }

    private func result(for failure: FrameSizingFailure,
                        actualFrames: [CGWindowID: CGRect]) -> Result {
        switch failure {
        case .deadlineExceeded, .superseded, .windowUnavailable:
            return Result(verdict: .unknown(failure), actualFrames: actualFrames)
        default:
            return Result(verdict: .rejected(failure), actualFrames: actualFrames)
        }
    }

    private func write(_ target: Target, actualFrames: [CGWindowID: CGRect],
                       checkpoint: () -> FrameSizingFailure?) -> Result? {
        if let failure = checkpoint() {
            return Result(verdict: .unknown(failure), actualFrames: actualFrames)
        }
        let token: AXFrameWriteBatch.Token
        switch io.beginFrameWrite(target.windowID, configuration.perCallTimeout, checkpoint) {
        case let .ready(value): token = value
        case let .failed(error):
            let failure: FrameSizingFailure = error == .invalidUIElement
                ? .windowUnavailable(target.windowID) : .writeFailed(target.windowID, error)
            return result(for: failure, actualFrames: actualFrames)
        case let .failedAfterCleanup(primary, cleanup):
            return beginCleanupFailure(target.windowID, primary: primary, cleanup: cleanup,
                                       actualFrames: actualFrames)
        case let .interrupted(reason):
            return Result(verdict: .unknown(reason), actualFrames: actualFrames)
        case let .interruptedAfterBegin(value, reason):
            return end(value, windowID: target.windowID,
                       preserving: Result(verdict: .unknown(reason), actualFrames: actualFrames),
                       checkpoint: checkpoint)
        }

        let writes: [() -> AXError] = [
            { io.writeSize(target.windowID, target.frame.size, configuration.perCallTimeout) },
            { io.writePosition(target.windowID, target.frame.origin, configuration.perCallTimeout) },
            { io.writeSize(target.windowID, target.frame.size, configuration.perCallTimeout) }
        ]
        for operation in writes {
            if let failure = prepare(target.windowID, checkpoint: checkpoint) {
                return end(token, windowID: target.windowID,
                           preserving: result(for: failure, actualFrames: actualFrames),
                           checkpoint: checkpoint)
            }
            let error = operation()
            let primary: Result
            if let failure = checkpoint() {
                primary = Result(verdict: .unknown(failure), actualFrames: actualFrames)
            } else if error != .success {
                primary = Result(verdict: .rejected(.writeFailed(target.windowID, error)),
                                 actualFrames: actualFrames)
            } else {
                continue
            }
            return end(token, windowID: target.windowID, preserving: primary,
                       checkpoint: checkpoint)
        }
        let ended = end(token, windowID: target.windowID,
                        preserving: Result(verdict: .accepted, actualFrames: actualFrames),
                        checkpoint: checkpoint)
        return ended.verdict == .accepted ? nil : ended
    }

    private func read(_ target: Target, actualFrames: inout [CGWindowID: CGRect],
                      checkpoint: () -> FrameSizingFailure?) -> Result? {
        if let failure = prepareRead(target.windowID, checkpoint: checkpoint) {
            return Result(verdict: .unknown(failure), actualFrames: actualFrames)
        }
        let (positionError, position) = io.readPosition(target.windowID, configuration.perCallTimeout)
        if let failure = checkpoint() {
            return Result(verdict: .unknown(failure), actualFrames: actualFrames)
        }
        guard positionError == .success, let position else {
            let failure: FrameSizingFailure = positionError == .invalidUIElement
                ? .windowUnavailable(target.windowID) : .readFailed(target.windowID, positionError)
            return Result(verdict: .unknown(failure), actualFrames: actualFrames)
        }
        if let failure = prepareRead(target.windowID, checkpoint: checkpoint) {
            return Result(verdict: .unknown(failure), actualFrames: actualFrames)
        }
        let (sizeError, size) = io.readSize(target.windowID, configuration.perCallTimeout)
        if let failure = checkpoint() {
            return Result(verdict: .unknown(failure), actualFrames: actualFrames)
        }
        guard sizeError == .success, let size else {
            let failure: FrameSizingFailure = sizeError == .invalidUIElement
                ? .windowUnavailable(target.windowID) : .readFailed(target.windowID, sizeError)
            return Result(verdict: .unknown(failure), actualFrames: actualFrames)
        }
        let frame = CGRect(origin: position, size: size)
        guard valid(frame) else {
            return Result(verdict: .unknown(.invalidFrame(target.windowID)), actualFrames: actualFrames)
        }
        actualFrames[target.windowID] = frame
        return nil
    }

    private func end(_ token: AXFrameWriteBatch.Token, windowID: CGWindowID,
                     preserving result: Result,
                     checkpoint: () -> FrameSizingFailure?) -> Result {
        switch io.endFrameWrite(token, configuration.perCallTimeout, checkpoint) {
        case .restored: return result
        case let .failed(error):
            return cleanupFailure(windowID, primary: result, error: error)
        case let .failedTimeoutAndRestore(timeout, restore):
            let nested = cleanupFailure(windowID, primary: result, error: timeout)
            return cleanupFailure(windowID, primary: nested, error: restore)
        }
    }

    private func cleanupFailure(_ windowID: CGWindowID, primary: Result,
                                error: AXError) -> Result {
        let reason: FrameSizingFailure?
        switch primary.verdict {
        case .accepted: reason = nil
        case let .rejected(failure), let .unknown(failure): reason = failure
        }
        return Result(verdict: .unknown(.cleanupFailed(windowID, primary: reason, error: error)),
                      actualFrames: primary.actualFrames)
    }

    private func beginCleanupFailure(_ windowID: CGWindowID, primary: AXError,
                                     cleanup: AXFrameWriteBatch.EndResult,
                                     actualFrames: [CGWindowID: CGRect]) -> Result {
        let primaryResult = Result(verdict: .unknown(.writeFailed(windowID, primary)),
                                   actualFrames: actualFrames)
        switch cleanup {
        case .restored: return primaryResult
        case let .failed(error):
            return cleanupFailure(windowID, primary: primaryResult, error: error)
        case let .failedTimeoutAndRestore(timeout, restore):
            let nested = cleanupFailure(windowID, primary: primaryResult, error: timeout)
            return cleanupFailure(windowID, primary: nested, error: restore)
        }
    }

    private func stable(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= configuration.stableTolerance
            && abs(lhs.minY - rhs.minY) <= configuration.stableTolerance
            && abs(lhs.width - rhs.width) <= configuration.stableTolerance
            && abs(lhs.height - rhs.height) <= configuration.stableTolerance
    }

    private func valid(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.size.width.isFinite && frame.size.height.isFinite
            && frame.width > 0 && frame.height > 0
    }

    private func matches(_ actual: CGRect, _ target: CGRect) -> Bool {
        abs(actual.minX - target.minX) <= configuration.positionTolerance
            && abs(actual.minY - target.minY) <= configuration.positionTolerance
            && matchesSize(actual.width, target.width)
            && matchesSize(actual.height, target.height)
    }

    /// Containment with the same bounded overshoot `matchesSize` allows.
    /// The origin must sit inside the usable frame within `positionTolerance`;
    /// the far edges may run past it by up to `sizeOvershootTolerance`. A
    /// cell-rounded window at the screen edge does exactly that whenever the
    /// outer padding is smaller than its cell. Restoration pins both
    /// tolerances to `sizeTolerance`, so a rollback still has to land inside.
    private func contained(_ actual: CGRect, in usableFrame: CGRect) -> Bool {
        actual.minX >= usableFrame.minX - configuration.positionTolerance
            && actual.minY >= usableFrame.minY - configuration.positionTolerance
            && actual.maxX <= usableFrame.maxX + configuration.sizeOvershootTolerance
            && actual.maxY <= usableFrame.maxY + configuration.sizeOvershootTolerance
    }

    private func matchesSize(_ actual: CGFloat, _ target: CGFloat) -> Bool {
        actual - target <= configuration.sizeOvershootTolerance
            && target - actual <= configuration.sizeUndershootTolerance
    }

    /// Pairwise checks, relaxed by the same bounded amount `matchesSize`
    /// allows. A window that rounds its size up to a whole character cell can
    /// eat into the gap, and up to one cell of its neighbour, so overlap and
    /// gap erosion within `sizeOvershootTolerance` are tolerated. Two windows
    /// genuinely stacked on top of each other overlap by far more than a cell
    /// on both axes and are still rejected. Containment is relaxed the same
    /// bounded way at the far edges only — see `contained(_:in:)`.
    func validateFrames(targets: [Target], actualFrames: [CGWindowID: CGRect],
                        usableFrame: CGRect, gap: CGFloat) -> Result {
        let tol = configuration.sizeOvershootTolerance
        for target in targets {
            guard let actual = actualFrames[target.windowID] else {
                return Result(verdict: .unknown(.windowUnavailable(target.windowID)), actualFrames: actualFrames)
            }
            guard contained(actual, in: usableFrame) else {
                return Result(verdict: .rejected(.outsideUsableFrame(target.windowID)), actualFrames: actualFrames)
            }
            if !matches(actual, target.frame) {
                return Result(verdict: .rejected(.geometryMismatch(target.windowID)), actualFrames: actualFrames)
            }
        }
        for i in targets.indices {
            for j in targets.indices where j > i {
                let first = targets[i]
                let second = targets[j]
                guard let actualA = actualFrames[first.windowID], let actualB = actualFrames[second.windowID] else { continue }
                if actualA.intersection(actualB).width > tol && actualA.intersection(actualB).height > tol {
                    return Result(verdict: .rejected(.overlap(first.windowID, second.windowID)), actualFrames: actualFrames)
                }
                let xSeparation = max(actualA.minX, actualB.minX) - min(actualA.maxX, actualB.maxX)
                let ySeparation = max(actualA.minY, actualB.minY) - min(actualA.maxY, actualB.maxY)
                if max(xSeparation, ySeparation) + 0.0001 < gap - tol {
                    return Result(verdict: .rejected(.gapViolation(first.windowID, second.windowID)), actualFrames: actualFrames)
                }
            }
        }
        return Result(verdict: .accepted, actualFrames: actualFrames)
    }

}

struct FrameSizingTransaction {
    enum Outcome: Equatable {
        case accepted(actualFrames: [CGWindowID: CGRect])
        case rejectedRestored(reason: FrameSizingFailure, actualFrames: [CGWindowID: CGRect])
        case degraded(candidateReason: FrameSizingFailure,
                      restorationReason: FrameSizingFailure?,
                      actualFrames: [CGWindowID: CGRect])
    }

    let attempt: FrameSizingAttempt

    func restore(originalFrames: [CGWindowID: CGRect], usableFrame: CGRect,
                 gap: CGFloat, generation: UInt64) -> FrameSizingAttempt.Result {
        let targets = originalFrames.map { FrameSizingAttempt.Target(windowID: $0.key, frame: $0.value) }
            .sorted { $0.windowID < $1.windowID }
        var strictAttempt = attempt
        strictAttempt.configuration.sizeOvershootTolerance = strictAttempt.configuration.sizeTolerance
        strictAttempt.configuration.sizeUndershootTolerance = strictAttempt.configuration.sizeTolerance
        return strictAttempt.apply(targets: targets, usableFrame: usableFrame,
                                   gap: gap, generation: generation)
    }

    func apply(targets: [FrameSizingAttempt.Target], originalFrames: [CGWindowID: CGRect],
               usableFrame: CGRect, gap: CGFloat, generation: UInt64) -> Outcome {
        guard Set(targets.map(\.windowID)) == Set(originalFrames.keys) else {
            return .degraded(candidateReason: .windowUnavailable(
                targets.first(where: { originalFrames[$0.windowID] == nil })?.windowID ?? 0),
                restorationReason: nil,
                actualFrames: [:])
        }
        let candidate = attempt.apply(targets: targets, usableFrame: usableFrame,
                                      gap: gap, generation: generation)
        switch candidate.verdict {
        case .accepted:
            return .accepted(actualFrames: candidate.actualFrames)
        case .unknown(.superseded):
            return .degraded(candidateReason: .superseded, restorationReason: nil,
                             actualFrames: candidate.actualFrames)
        case let .rejected(reason), let .unknown(reason):
            guard attempt.io.currentGeneration() == generation else {
                return .degraded(candidateReason: reason, restorationReason: nil,
                                 actualFrames: candidate.actualFrames)
            }
            let restored = restore(originalFrames: originalFrames, usableFrame: usableFrame,
                                   gap: gap, generation: generation)
            switch restored.verdict {
            case .accepted:
                return .rejectedRestored(reason: reason, actualFrames: restored.actualFrames)
            case let .rejected(restoreReason), let .unknown(restoreReason):
                return .degraded(candidateReason: reason, restorationReason: restoreReason,
                                 actualFrames: restored.actualFrames)
            }
        }
    }
}
