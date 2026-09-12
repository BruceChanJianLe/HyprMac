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
        guard generation() == requestedGeneration else {
            return Result(verdict: .unknown(.superseded), actualFrames: [:],
                          conflicts: [], observations: [], accepted: [])
        }
        guard !layouts.isEmpty else {
            return Result(verdict: .accepted, actualFrames: [:], conflicts: [],
                          observations: [], accepted: [])
        }
        let ids = layouts.map { $0.0.windowID }
        if let duplicate = ids.first(where: { id in ids.filter { $0 == id }.count > 1 }) {
            return Result(verdict: .rejected(.duplicateWindowID(duplicate)),
                          actualFrames: [:], conflicts: [],
                          observations: [], accepted: [])
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
            usableFrame: usableFrame, gap: gap, generation: requestedGeneration
        )
        return classify(raw, layouts: layouts)
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
                    generation: requestedGeneration)
    }

    private func classify(_ raw: FrameSizingAttempt.Result,
                          layouts: [(HyprWindow, CGRect)]) -> Result {
        var conflicts: [Conflict] = []
        var observations: [Observation] = []
        var accepted: [(HyprWindow, CGSize)] = []
        for (window, target) in layouts {
            guard let actual = raw.actualFrames[window.windowID] else { continue }
            if case .unknown = raw.verdict { continue }
            window.cachedFrame = actual
            let widthConflict = actual.width > target.width + configuration.sizeTolerance
            let heightConflict = actual.height > target.height + configuration.sizeTolerance
            if widthConflict || heightConflict, case .rejected = raw.verdict {
                conflicts.append(Conflict(window: window, allocated: target, actual: actual.size))
                observations.append(Observation(window: window, actual: actual.size,
                                                widthConflict: widthConflict,
                                                heightConflict: heightConflict))
            } else if raw.verdict == .accepted {
                accepted.append((window, actual.size))
            }
        }
        return Result(verdict: raw.verdict, actualFrames: raw.actualFrames,
                      conflicts: conflicts, observations: observations,
                      accepted: accepted)
    }

}
