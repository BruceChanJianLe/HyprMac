// `--probe-frame`: one AX frame write against one window, with every
// raw error and both readbacks written to a file. Debug builds only.
// Exists because the live log shows only the final verdict — this asks
// the same question `FrameSizingAttempt` asks, in isolation, with the
// window manager not running.

#if DEBUG
import Cocoa

/// Parsed `--probe-frame <windowID> <x> <y> <w> <h> [--order …] [--out …]`.
/// Pure: no AX, no filesystem. `ProbeFrame.run` does the work.
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

/// Runs one parsed probe and exits the process. Never returns.
enum ProbeFrame {
    static let messagingTimeout: TimeInterval = 1.0
    static let settleDelay: TimeInterval = 0.3

    static func run(_ arguments: ProbeFrameArguments) -> Never {
        var lines: [String] = [
            "probe-frame wid=\(arguments.windowID) target=\(text(arguments.frame))",
            "order=\(arguments.order.rawValue)",
            "trusted=\(AXIsProcessTrusted())"
        ]

        guard AXIsProcessTrusted() else {
            return finish(lines + ["error: accessibility not granted"], arguments, failed: true)
        }
        guard let found = AccessibilityManager().axWindow(forWindowID: arguments.windowID) else {
            return finish(lines + ["error: no AX window for id \(arguments.windowID)"],
                          arguments, failed: true)
        }

        let window = HyprWindow(element: found.element, windowID: arguments.windowID,
                                ownerPID: found.ownerPID)
        lines.append("pid=\(found.ownerPID)")
        var failed = false

        let timeoutError = window.setMessagingTimeout(messagingTimeout)
        if timeoutError != .success {
            failed = true
            lines.append("messaging timeout err=\(timeoutError.rawValue)")
        }

        let before = read(window, label: "before")
        lines += before.lines
        failed = failed || before.frame == nil

        for (index, step) in arguments.order.steps.enumerated() {
            let error: AXError
            switch step {
            case .size: error = window.writeSize(arguments.frame.size)
            case .position: error = window.writePosition(arguments.frame.origin)
            }
            if error != .success { failed = true }
            lines.append("write \(index + 1) \(step.rawValue) err=\(error.rawValue)")
        }

        Thread.sleep(forTimeInterval: settleDelay)

        let after = read(window, label: "after")
        lines += after.lines
        failed = failed || after.frame == nil

        if let actual = after.frame {
            lines.append("delta=(\(text(actual.width - arguments.frame.width)),"
                         + "\(text(actual.height - arguments.frame.height))) "
                         + "dx=\(text(actual.minX - arguments.frame.minX)),"
                         + "dy=\(text(actual.minY - arguments.frame.minY))")
        }

        lines += screenLines(windowFrame: after.frame)
        return finish(lines, arguments, failed: failed)
    }

    /// AX position and size as one labelled pair, plus the CG rect they
    /// make. Errors carry their raw code and fail the probe.
    private static func read(_ window: HyprWindow, label: String) -> (lines: [String], frame: CGRect?) {
        let (positionError, position) = window.readPosition()
        let (sizeError, size) = window.readSize()
        guard positionError == .success, sizeError == .success,
              let position, let size else {
            return (["\(label): position err=\(positionError.rawValue) "
                     + "size err=\(sizeError.rawValue)"], nil)
        }
        let frame = CGRect(origin: position, size: size)
        return (["\(label): \(text(frame))"], frame)
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
