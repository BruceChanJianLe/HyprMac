import Cocoa

struct FrameReadbackPoller {
    struct Conflict {
        let window: HyprWindow
        let allocated: CGRect
        let actual: CGSize
    }

    struct Observation {
        let window: HyprWindow
        let actual: CGSize
        let widthConflict: Bool
        let heightConflict: Bool
    }

    struct Result {
        let verdict: FrameSizingAttempt.Verdict
        let actualFrames: [CGWindowID: CGRect]
        let conflicts: [Conflict]
        let observations: [Observation]
        let accepted: [(HyprWindow, CGSize)]
        var progress = FrameSizingAttempt.Progress()
    }

    private let configuration: FrameSizingConfiguration
    private let generation: () -> UInt64
    private let ioFactory: ([CGWindowID: HyprWindow], @escaping () -> UInt64) -> FrameSizingIO

    init(configuration: FrameSizingConfiguration = FrameSizingConfiguration(),
         generation: @escaping () -> UInt64 = { 0 },
         ioFactory: @escaping ([CGWindowID: HyprWindow], @escaping () -> UInt64) -> FrameSizingIO = FrameSizingIO.accessibility) {
        self.configuration = configuration
        self.generation = generation
        self.ioFactory = ioFactory
    }

    func applyLayout(_ layouts: [(HyprWindow, CGRect)], usableFrame: CGRect,
                     gap: CGFloat, generation requestedGeneration: UInt64) -> Result {
        applyLayout(layouts, usableFrame: usableFrame, gap: gap,
                    generation: requestedGeneration, configuration: configuration,
                    phase: .candidate)
    }

    func applyRestoration(_ layouts: [(HyprWindow, CGRect)], usableFrame: CGRect,
                          gap: CGFloat, generation requestedGeneration: UInt64) -> Result {
        var strictConfiguration = configuration
        strictConfiguration.sizeOvershootTolerance = strictConfiguration.sizeTolerance
        strictConfiguration.sizeUndershootTolerance = strictConfiguration.sizeTolerance
        return applyLayout(layouts, usableFrame: usableFrame, gap: gap,
                           generation: requestedGeneration, configuration: strictConfiguration,
                           phase: .restoration)
    }

    private func applyLayout(_ layouts: [(HyprWindow, CGRect)], usableFrame: CGRect,
                             gap: CGFloat, generation requestedGeneration: UInt64,
                             configuration: FrameSizingConfiguration,
                             phase: FrameSizingPhase) -> Result {
        let ids = layouts.map { $0.0.windowID }
        let unstarted = FrameSizingAttempt.Progress(phase: phase, generation: requestedGeneration,
                                                    targetIDs: ids)
        guard generation() == requestedGeneration else {
            return Result(verdict: .unknown(.superseded), actualFrames: [:],
                          conflicts: [], observations: [], accepted: [], progress: unstarted)
        }
        guard !layouts.isEmpty else {
            return Result(verdict: .accepted, actualFrames: [:], conflicts: [],
                          observations: [], accepted: [], progress: unstarted)
        }
        if let duplicate = ids.first(where: { id in ids.filter { $0 == id }.count > 1 }) {
            return Result(verdict: .rejected(.duplicateWindowID(duplicate)),
                          actualFrames: [:], conflicts: [],
                          observations: [], accepted: [], progress: unstarted)
        }
        let windows = Dictionary(uniqueKeysWithValues: layouts.map { ($0.0.windowID, $0.0) })
        if generation() == requestedGeneration {
            for (window, _) in layouts { window.cachedFrame = nil }
        }
        let attempt = FrameSizingAttempt(
            io: ioFactory(windows, generation),
            configuration: configuration
        )
        let raw = attempt.apply(
            targets: layouts.map { .init(windowID: $0.0.windowID, frame: $0.1) },
            usableFrame: usableFrame, gap: gap, generation: requestedGeneration,
            phase: phase
        )
        return classify(raw, layouts: layouts, configuration: configuration)
    }

    func captureFrames(_ windows: [HyprWindow], generation requestedGeneration: UInt64) -> FrameSizingAttempt.Result {
        var seen = Set<CGWindowID>()
        for window in windows where !seen.insert(window.windowID).inserted {
            return FrameSizingAttempt.Result(verdict: .unknown(.duplicateWindowID(window.windowID)),
                                             actualFrames: [:])
        }
        let windowMap = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        return FrameSizingAttempt(io: ioFactory(windowMap, generation), configuration: configuration)
            .captureFrames(windowIDs: windows.map(\.windowID), generation: requestedGeneration)
    }

    @discardableResult
    func applyFinal(_ layouts: [(HyprWindow, CGRect)], usableFrame: CGRect,
                    gap: CGFloat, generation requestedGeneration: UInt64) -> Result {
        applyLayout(layouts, usableFrame: usableFrame, gap: gap,
                    generation: requestedGeneration, configuration: configuration,
                    phase: .adjusted)
    }

    private func classify(_ raw: FrameSizingAttempt.Result,
                          layouts: [(HyprWindow, CGRect)],
                          configuration: FrameSizingConfiguration) -> Result {
        var conflicts: [Conflict] = []
        var observations: [Observation] = []
        var accepted: [(HyprWindow, CGSize)] = []
        let phase = raw.progress.phase
        for (window, target) in layouts {
            guard let actual = raw.actualFrames[window.windowID] else { continue }
            if case .unknown = raw.verdict { continue }
            window.cachedFrame = actual
            // cell rounding is not a min-size floor, so it must not teach one
            let widthConflict = actual.width > target.width + configuration.sizeOvershootTolerance
            let heightConflict = actual.height > target.height + configuration.sizeOvershootTolerance
            if widthConflict || heightConflict, case .rejected = raw.verdict {
                conflicts.append(Conflict(window: window, allocated: target, actual: actual.size))
                observations.append(Observation(window: window, actual: actual.size,
                                                widthConflict: widthConflict,
                                                heightConflict: heightConflict))
                hyprLog(.debug, .tiling, "min evidence: wid=\(window.windowID) "
                        + "phase=\(phase.rawValue) "
                        + "target=\(Self.size(target.size)) actual=\(Self.size(actual.size)) "
                        + "axis=\(Self.axis(width: widthConflict, height: heightConflict)) "
                        + "written=\(raw.progress.possiblyWritten.contains(window.windowID)) "
                        + "complete=\(raw.progress.writesCompleted.contains(window.windowID)) "
                        + "stable=\(raw.progress.readbackStable) source=readback")
            } else if raw.verdict == .accepted {
                accepted.append((window, actual.size))
            }
        }
        return Result(verdict: raw.verdict, actualFrames: raw.actualFrames,
                      conflicts: conflicts, observations: observations,
                      accepted: accepted, progress: raw.progress)
    }

    static func axis(width: Bool, height: Bool) -> String {
        switch (width, height) {
        case (true, true): return "width+height"
        case (true, false): return "width"
        case (false, true): return "height"
        case (false, false): return "none"
        }
    }

    private static func size(_ size: CGSize) -> String {
        String(format: "%gx%g", Double(size.width), Double(size.height))
    }

}
