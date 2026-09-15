import Cocoa

struct AXFrameWriteBatch {
    final class Application {
        fileprivate let element: AXUIElement?

        init() {
            element = nil
        }

        fileprivate init(element: AXUIElement) {
            self.element = element
        }
    }

    struct RawOperations {
        let makeApplication: (pid_t) -> Application
        let setApplicationTimeout: (Application, TimeInterval) -> AXError
        let copyEnhancedUI: (Application) -> (AXError, AnyObject?)
        let setEnhancedUI: (Application, Bool) -> AXError
    }

    struct Token: Equatable {
        fileprivate let ownerPID: pid_t
        fileprivate let application: Application
        fileprivate let restoreEnhancedUI: Bool

        static func == (lhs: Token, rhs: Token) -> Bool {
            lhs.ownerPID == rhs.ownerPID
                && lhs.application === rhs.application
                && lhs.restoreEnhancedUI == rhs.restoreEnhancedUI
        }

        static func noop(windowID: CGWindowID) -> Token {
            Token(ownerPID: pid_t(windowID),
                  application: Application(),
                  restoreEnhancedUI: false)
        }
    }

    enum BeginResult: Equatable {
        case ready(Token)
        case failed(AXError)
        case failedAfterCleanup(primary: AXError, cleanup: EndResult)
        case interrupted(FrameSizingFailure)
        case interruptedAfterBegin(Token, FrameSizingFailure)
    }

    enum EndResult: Equatable {
        case restored
        case failed(AXError)
        case failedTimeoutAndRestore(timeout: AXError, restore: AXError)
    }

    let raw: RawOperations

    func begin(ownerPID: pid_t, timeout: TimeInterval,
               checkpoint: () -> FrameSizingFailure?) -> BeginResult {
        if let failure = checkpoint() { return .interrupted(failure) }
        let application = raw.makeApplication(ownerPID)
        let timeoutError = raw.setApplicationTimeout(application, timeout)
        if let failure = checkpoint() { return .interrupted(failure) }
        guard timeoutError == .success else {
            hyprLog(.debug, .tiling, "enhanced ui: pid=\(ownerPID) begin timeout err=\(timeoutError.rawValue)")
            return .failed(timeoutError)
        }

        let (readError, value) = raw.copyEnhancedUI(application)
        if let failure = checkpoint() { return .interrupted(failure) }
        if readError == .attributeUnsupported || readError == .noValue {
            return .ready(Token(ownerPID: ownerPID, application: application, restoreEnhancedUI: false))
        }
        guard readError == .success else {
            hyprLog(.debug, .tiling, "enhanced ui: pid=\(ownerPID) begin read err=\(readError.rawValue)")
            return .failed(readError)
        }
        guard let value, CFGetTypeID(value) == CFBooleanGetTypeID() else {
            hyprLog(.debug, .tiling, "enhanced ui: pid=\(ownerPID) begin read gave a non-boolean")
            return .failed(.failure)
        }
        guard let enhancedUI = value as? Bool else { return .failed(.failure) }
        guard enhancedUI else {
            return .ready(Token(ownerPID: ownerPID, application: application, restoreEnhancedUI: false))
        }

        let toggleTimeoutError = raw.setApplicationTimeout(application, timeout)
        if let failure = checkpoint() { return .interrupted(failure) }
        guard toggleTimeoutError == .success else {
            hyprLog(.debug, .tiling, "enhanced ui: pid=\(ownerPID) begin toggle timeout err=\(toggleTimeoutError.rawValue)")
            return .failed(toggleTimeoutError)
        }
        let disableError = raw.setEnhancedUI(application, false)
        if disableError == .notImplemented {
            if let failure = checkpoint() { return .interrupted(failure) }
            return .ready(Token(ownerPID: ownerPID, application: application,
                                restoreEnhancedUI: false))
        }
        let token = Token(ownerPID: ownerPID, application: application, restoreEnhancedUI: true)
        guard disableError == .success else {
            hyprLog(.debug, .tiling, "enhanced ui: pid=\(ownerPID) begin disable err=\(disableError.rawValue)")
            let cleanup = end(token, timeout: timeout, checkpoint: checkpoint)
            return cleanup == .restored
                ? .failed(disableError)
                : .failedAfterCleanup(primary: disableError, cleanup: cleanup)
        }
        if let failure = checkpoint() { return .interruptedAfterBegin(token, failure) }
        return .ready(token)
    }

    func end(_ token: Token, timeout: TimeInterval,
             checkpoint: () -> FrameSizingFailure?) -> EndResult {
        _ = checkpoint()
        guard token.restoreEnhancedUI else { return .restored }
        let timeoutError = raw.setApplicationTimeout(token.application, timeout)
        _ = checkpoint()
        let restoreError = raw.setEnhancedUI(token.application, true)
        _ = checkpoint()
        if timeoutError != .success || restoreError != .success {
            hyprLog(.debug, .tiling, "enhanced ui: pid=\(token.ownerPID) end timeout err=\(timeoutError.rawValue) restore err=\(restoreError.rawValue)")
        }
        switch (timeoutError, restoreError) {
        case (.success, .success):
            return .restored
        case let (.success, error):
            return .failed(error)
        case let (error, .success):
            return .failed(error)
        case let (timeoutError, restoreError):
            return .failedTimeoutAndRestore(timeout: timeoutError, restore: restoreError)
        }
    }
}

extension AXFrameWriteBatch {
    static let accessibility = AXFrameWriteBatch(raw: RawOperations(
        makeApplication: { ownerPID in
            Application(element: AXUIElementCreateApplication(ownerPID))
        },
        setApplicationTimeout: { application, timeout in
            guard let element = application.element else { return .illegalArgument }
            return AXUIElementSetMessagingTimeout(element, Float(timeout))
        },
        copyEnhancedUI: { application in
            guard let element = application.element else { return (.illegalArgument, nil) }
            var value: AnyObject?
            let error = AXUIElementCopyAttributeValue(
                element,
                "AXEnhancedUserInterface" as CFString,
                &value
            )
            return (error, value)
        },
        setEnhancedUI: { application, enabled in
            guard let element = application.element else { return .illegalArgument }
            return AXUIElementSetAttributeValue(
                element,
                "AXEnhancedUserInterface" as CFString,
                enabled ? kCFBooleanTrue : kCFBooleanFalse
            )
        }
    ))
}

enum AXFrameValueDecoder {
    static func point(error: AXError, value: AnyObject?) -> (AXError, CGPoint?) {
        guard error == .success else { return (error, nil) }
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return (.failure, nil) }
        // cf type id checked above
        // swiftlint:disable:next force_cast
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return (.failure, nil) }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point), point.x.isFinite, point.y.isFinite else {
            return (.failure, nil)
        }
        return (.success, point)
    }

    static func size(error: AXError, value: AnyObject?) -> (AXError, CGSize?) {
        guard error == .success else { return (error, nil) }
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return (.failure, nil) }
        // cf type id checked above
        // swiftlint:disable:next force_cast
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return (.failure, nil) }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size),
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else {
            return (.failure, nil)
        }
        return (.success, size)
    }
}
