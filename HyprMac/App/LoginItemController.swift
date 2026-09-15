import AppKit
import Combine
import ServiceManagement

/// Coordinates HyprMac's login item without changing it until the user asks.
@MainActor
final class LoginItemController: ObservableObject {
    enum ServiceStatus: Equatable {
        case notRegistered
        case enabled
        case requiresApproval
        case unavailable
    }

    enum State: Equatable {
        case notEnabled
        case enabled
        case requiresApproval
        case failed
    }

    typealias StatusProvider = @MainActor () -> ServiceStatus
    typealias RegisterAction = @MainActor () throws -> Void
    typealias OpenSettingsAction = @MainActor () -> Void

    @Published private(set) var state: State = .notEnabled
    let appName: String

    private let statusProvider: StatusProvider
    private let registerAction: RegisterAction
    private let openSettingsAction: OpenSettingsAction

    init(
        appName: String = LoginItemController.defaultAppName,
        status: @escaping StatusProvider = LoginItemController.liveStatus,
        register: @escaping RegisterAction = LoginItemController.liveRegister,
        openSettings: @escaping OpenSettingsAction = LoginItemController.openSystemSettingsLoginItems
    ) {
        self.appName = appName
        self.statusProvider = status
        self.registerAction = register
        self.openSettingsAction = openSettings
    }

    var instructionText: String? {
        switch state {
        case .requiresApproval:
            return "In System Settings → General → Login Items, allow \(appName). If it appears under Allow in the Background, turn it on there."
        case .failed:
            return "In System Settings → General → Login Items, click + under Open at Login, select \(appName), then click Add."
        case .notEnabled, .enabled:
            return nil
        }
    }

    /// Reads the current service state. This never registers or opens Settings.
    func refresh() {
        apply(statusProvider())
    }

    /// Attempts registration only in response to an explicit user action.
    func enable() {
        switch statusProvider() {
        case .enabled:
            state = .enabled
            return
        case .requiresApproval:
            state = .requiresApproval
            openSettingsAction()
            return
        case .notRegistered, .unavailable:
            break
        }

        do {
            try registerAction()
            switch statusProvider() {
            case .enabled:
                state = .enabled
            case .requiresApproval:
                state = .requiresApproval
                openSettingsAction()
            case .notRegistered, .unavailable:
                state = .failed
                openSettingsAction()
            }
        } catch {
            state = .failed
            openSettingsAction()
        }
    }

    func openLoginItems() {
        openSettingsAction()
    }

    private func apply(_ status: ServiceStatus) {
        switch status {
        case .enabled:
            state = .enabled
        case .requiresApproval:
            state = .requiresApproval
        case .notRegistered, .unavailable:
            if state != .failed {
                state = .notEnabled
            }
        }
    }

    nonisolated static var defaultAppName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "HyprMac"
    }

    static func liveStatus() -> ServiceStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    static func liveRegister() throws {
        try SMAppService.mainApp.register()
    }

    static func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
