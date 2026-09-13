// `--probe-frame`: one AX frame write against one window, with every
// raw error and both readbacks written to a file. Debug builds only.
// Exists because the live log shows only the final verdict — this asks
// the same question `FrameSizingAttempt` asks, in isolation, with the
// window manager not running.

#if DEBUG
import Cocoa

/// Parsed `--probe-frame <windowID> <x> <y> <w> <h> [--order …] [--out …]
/// [--wrapper] [--restore]`. Pure: no AX, no filesystem.
/// `ProbeFrame.run` does the work.
struct ProbeFrameArguments: Equatable {
    /// Write sequence. `sizePositionSize` mirrors `FrameSizingAttempt`.
    enum Order: String, Equatable {
        case sizePositionSize = "size-position-size"
        case positionSize = "position-size"
        case sizeOnly = "size-only"

        var steps: [Step] {
            switch self {
            case .sizePositionSize: return [.size, .position, .size]
            case .positionSize: return [.position, .size]
            case .sizeOnly: return [.size]
            }
        }
    }

    enum Step: String, Equatable {
        case size, position
    }

    enum Failure: Equatable, Error {
        case missingValues
        case invalidWindowID(String)
        case invalidNumber(String)
        case emptySize
        case unknownOrder(String)
        case missingValue(String)
        case unknownFlag(String)
    }

    static let flag = "--probe-frame"
    static let defaultOutputPath = "/tmp/hyprmac-probe-frame.txt"

    let windowID: CGWindowID
    let frame: CGRect
    var order: Order = .sizePositionSize
    var outputPath: String = ProbeFrameArguments.defaultOutputPath
    /// Bracket the writes in the AXEnhancedUserInterface toggle
    /// production uses, so the probe and `FrameSizingAttempt` differ only
    /// in timing.
    var wrapper: Bool = false
    /// Write the frame read before the probe back at the end, and report
    /// that readback and its status separately.
    var restore: Bool = false

    /// `nil` when this is not a probe launch at all, so the caller can
    /// tell "no probe asked for" from "probe asked for, badly".
    static func parse(_ arguments: [String]) -> Result<ProbeFrameArguments, Failure>? {
        guard let start = arguments.firstIndex(of: flag) else { return nil }
        let rest = Array(arguments[(start + 1)...])
        guard rest.count >= 5 else { return .failure(.missingValues) }
        guard let windowID = CGWindowID(rest[0]) else { return .failure(.invalidWindowID(rest[0])) }

        var numbers: [CGFloat] = []
        for token in rest[1..<5] {
            guard let value = Double(token), value.isFinite else {
                return .failure(.invalidNumber(token))
            }
            numbers.append(CGFloat(value))
        }
        guard numbers[2] > 0, numbers[3] > 0 else { return .failure(.emptySize) }

        var parsed = ProbeFrameArguments(
            windowID: windowID,
            frame: CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        )
        var index = 5
        while index < rest.count {
            let token = rest[index]
            switch token {
            case "--order":
                guard index + 1 < rest.count else { return .failure(.missingValue(token)) }
                guard let order = Order(rawValue: rest[index + 1]) else {
                    return .failure(.unknownOrder(rest[index + 1]))
                }
                parsed.order = order
                index += 2
            case "--out":
                guard index + 1 < rest.count else { return .failure(.missingValue(token)) }
                parsed.outputPath = rest[index + 1]
                index += 2
            case "--wrapper":
                parsed.wrapper = true
                index += 1
            case "--restore":
                parsed.restore = true
                index += 1
            default:
                // launch services appends its own arguments (-psn_0_…);
                // only a mistyped long flag is worth failing on.
                if token.hasPrefix("--") { return .failure(.unknownFlag(token)) }
                index += 1
            }
        }
        return .success(parsed)
    }
}

/// Every AX call the probe makes, behind closures, so the report shape
/// and the restoration ordering are testable without a desktop window.
struct ProbeFrameOperations {
    var trusted: () -> Bool
    /// Owning pid, or nil when no AX window matches the id.
    var resolve: (CGWindowID) -> pid_t?
    var setMessagingTimeout: (TimeInterval) -> AXError
    var readPosition: () -> (AXError, CGPoint?)
    var readSize: () -> (AXError, CGSize?)
    var readMinimumSize: () -> CGSize?
    var writeSize: (CGSize) -> AXError
    var writePosition: (CGPoint) -> AXError
    var beginWrapper: (pid_t, TimeInterval) -> AXFrameWriteBatch.BeginResult
    var endWrapper: (AXFrameWriteBatch.Token, TimeInterval) -> AXFrameWriteBatch.EndResult
    var sleep: (TimeInterval) -> Void
    var now: () -> TimeInterval
    var screenLines: (CGRect?) -> [String]
}

/// Runs one parsed probe and exits the process.
enum ProbeFrame {
    static let messagingTimeout: TimeInterval = 1.0
    static let firstReadDelay: TimeInterval = 0.3
    static let secondReadDelay: TimeInterval = 1.0

    static func run(_ arguments: ProbeFrameArguments) -> Never {
        let report = execute(arguments, operations: accessibilityOperations())
        return finish(report.lines, arguments, failed: report.failed)
    }

    /// The probe itself. Returns the report body and whether any AX call
    /// failed — including a failed restoration.
    static func execute(_ arguments: ProbeFrameArguments,
                        operations: ProbeFrameOperations) -> (lines: [String], failed: Bool) {
        var lines: [String] = [
            "probe-frame wid=\(arguments.windowID) target=\(text(arguments.frame))",
            "order=\(arguments.order.rawValue) wrapper=\(arguments.wrapper) "
                + "restore=\(arguments.restore)",
            "trusted=\(operations.trusted())"
        ]

        guard operations.trusted() else {
            return (lines + ["error: accessibility not granted"], true)
        }
        guard let ownerPID = operations.resolve(arguments.windowID) else {
            return (lines + ["error: no AX window for id \(arguments.windowID)"], true)
        }
        lines.append("pid=\(ownerPID)")
        var failed = false

        let timeoutError = operations.setMessagingTimeout(messagingTimeout)
        if timeoutError != .success {
            failed = true
            lines.append("messaging timeout err=\(timeoutError.rawValue)")
        }

        if let minimum = operations.readMinimumSize() {
            lines.append("ax minimum=\(text(minimum.width))x\(text(minimum.height))")
        } else {
            lines.append("ax minimum=unreadable")
        }

        let started = operations.now()
        let before = read(operations, label: "before", started: started, now: operations.now)
        lines += before.lines
        failed = failed || before.frame == nil

        var token: AXFrameWriteBatch.Token?
        if arguments.wrapper {
            switch operations.beginWrapper(ownerPID, messagingTimeout) {
            case let .ready(value):
                token = value
                lines.append("wrapper begin=ready")
            case let .failed(error):
                failed = true
                lines.append("wrapper begin err=\(error.rawValue)")
            case let .failedAfterCleanup(primary, cleanup):
                failed = true
                lines.append("wrapper begin err=\(primary.rawValue) cleanup=\(cleanup)")
            case let .interrupted(reason):
                failed = true
                lines.append("wrapper begin interrupted=\(reason)")
            case let .interruptedAfterBegin(value, reason):
                failed = true
                token = value
                lines.append("wrapper begin interrupted=\(reason)")
            }
        }

        for (index, step) in arguments.order.steps.enumerated() {
            let error: AXError
            switch step {
            case .size: error = operations.writeSize(arguments.frame.size)
            case .position: error = operations.writePosition(arguments.frame.origin)
            }
            if error != .success { failed = true }
            lines.append("write \(index + 1) \(step.rawValue) err=\(error.rawValue) "
                         + "at=\(text(CGFloat(operations.now() - started)))s")
        }

        if let token {
            let end = operations.endWrapper(token, messagingTimeout)
            if end != .restored { failed = true }
            lines.append("wrapper end=\(end)")
        }

        let writesFinished = operations.now()
        operations.sleep(firstReadDelay)
        let early = read(operations, label: "after \(text(CGFloat(firstReadDelay)))s",
                         started: writesFinished, now: operations.now)
        lines += early.lines
        failed = failed || early.frame == nil
        if let actual = early.frame { lines.append(delta(actual, arguments.frame)) }

        operations.sleep(secondReadDelay - firstReadDelay)
        let late = read(operations, label: "after \(text(CGFloat(secondReadDelay)))s",
                        started: writesFinished, now: operations.now)
        lines += late.lines
        failed = failed || late.frame == nil
        if let actual = late.frame { lines.append(delta(actual, arguments.frame)) }

        lines += operations.screenLines(late.frame ?? early.frame)

        // restoration is the last thing the probe does, and it reports its
        // own readback and status so a good probe with a bad restore is not
        // mistaken for a clean run
        if arguments.restore {
            guard let baseline = before.frame else {
                return (lines + ["restore: skipped, no readable baseline", "restore result=error"],
                        true)
            }
            lines.append("restore target=\(text(baseline))")
            var restoreFailed = false
            for step in ProbeFrameArguments.Order.sizePositionSize.steps {
                let error: AXError
                switch step {
                case .size: error = operations.writeSize(baseline.size)
                case .position: error = operations.writePosition(baseline.origin)
                }
                if error != .success { restoreFailed = true }
                lines.append("restore write \(step.rawValue) err=\(error.rawValue)")
            }
            operations.sleep(firstReadDelay)
            let restored = read(operations, label: "restore readback",
                                started: operations.now(), now: operations.now)
            lines += restored.lines
            if let actual = restored.frame {
                lines.append("restore " + delta(actual, baseline))
            } else {
                restoreFailed = true
            }
            lines.append("restore result=\(restoreFailed ? "error" : "ok")")
            failed = failed || restoreFailed
        }

        return (lines, failed)
    }

    /// AX position and size as one labelled pair, plus the CG rect they
    /// make. Errors carry their raw code and fail the probe.
    private static func read(_ operations: ProbeFrameOperations, label: String,
                             started: TimeInterval,
                             now: () -> TimeInterval) -> (lines: [String], frame: CGRect?) {
        let (positionError, position) = operations.readPosition()
        let (sizeError, size) = operations.readSize()
        let stamp = "t=\(text(CGFloat(now() - started)))s"
        guard positionError == .success, sizeError == .success,
              let position, let size else {
            return (["\(label): position err=\(positionError.rawValue) "
                     + "size err=\(sizeError.rawValue) \(stamp)"], nil)
        }
        let frame = CGRect(origin: position, size: size)
        return (["\(label): \(text(frame)) \(stamp)"], frame)
    }

    private static func delta(_ actual: CGRect, _ target: CGRect) -> String {
        "delta=(\(text(actual.width - target.width)),"
            + "\(text(actual.height - target.height))) "
            + "dx=\(text(actual.minX - target.minX)),"
            + "dy=\(text(actual.minY - target.minY))"
    }

    private static func accessibilityOperations() -> ProbeFrameOperations {
        var window: HyprWindow?
        return ProbeFrameOperations(
            trusted: { AXIsProcessTrusted() },
            resolve: { windowID in
                guard let found = AccessibilityManager().axWindow(forWindowID: windowID) else {
                    return nil
                }
                window = HyprWindow(element: found.element, windowID: windowID,
                                    ownerPID: found.ownerPID)
                return found.ownerPID
            },
            setMessagingTimeout: { window?.setMessagingTimeout($0) ?? .invalidUIElement },
            readPosition: { window?.readPosition() ?? (.invalidUIElement, nil) },
            readSize: { window?.readSize() ?? (.invalidUIElement, nil) },
            readMinimumSize: { window?.axMinimumSize() },
            writeSize: { window?.writeSize($0) ?? .invalidUIElement },
            writePosition: { window?.writePosition($0) ?? .invalidUIElement },
            beginWrapper: { pid, timeout in
                AXFrameWriteBatch.accessibility.begin(ownerPID: pid, timeout: timeout,
                                                      checkpoint: { nil })
            },
            endWrapper: { token, timeout in
                AXFrameWriteBatch.accessibility.end(token, timeout: timeout, checkpoint: { nil })
            },
            sleep: { Thread.sleep(forTimeInterval: $0) },
            now: { ProcessInfo.processInfo.systemUptime },
            screenLines: { screenLines(windowFrame: $0) }
        )
    }

    /// Every screen's frame and visibleFrame in both coordinate spaces,
    /// with the one holding the window marked. CG conversion uses
    /// `DisplayManager.cgRect` semantics: anchored on the primary
    /// screen's height, top-left origin.
    private static func screenLines(windowFrame: CGRect?) -> [String] {
        let displays = DisplayManager()
        let primaryHeight = displays.primaryScreenHeight
        func cg(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.origin.x, y: primaryHeight - rect.origin.y - rect.height,
                   width: rect.width, height: rect.height)
        }
        var lines = ["primary height=\(text(primaryHeight))"]
        for (index, screen) in displays.screens.enumerated() {
            let owner = windowFrame.map { cg(screen.frame).contains(CGPoint(x: $0.midX, y: $0.midY)) }
            lines.append("screen \(index): owner=\(owner.map(String.init) ?? "?") "
                         + "frame.ns=\(text(screen.frame)) "
                         + "frame.cg=\(text(cg(screen.frame))) "
                         + "visible.ns=\(text(screen.visibleFrame)) "
                         + "visible.cg=\(text(displays.cgRect(for: screen)))")
        }
        return lines
    }

    private static func finish(_ lines: [String], _ arguments: ProbeFrameArguments,
                               failed: Bool) -> Never {
        let body = (lines + ["result=\(failed ? "error" : "ok")"]).joined(separator: "\n") + "\n"
        do {
            try body.write(toFile: arguments.outputPath, atomically: true, encoding: .utf8)
        } catch {
            print("probe-frame could not write \(arguments.outputPath): \(error)")
        }
        print(body, terminator: "")
        fflush(stdout)
        exit(failed ? 1 : 0)
    }

    private static func text(_ value: CGFloat) -> String {
        String(format: "%g", Double(value))
    }

    private static func text(_ rect: CGRect) -> String {
        "(\(text(rect.minX)),\(text(rect.minY)),\(text(rect.width)),\(text(rect.height)))"
    }
}
#endif
