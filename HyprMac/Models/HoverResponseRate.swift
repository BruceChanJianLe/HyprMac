import Foundation

enum HoverResponseRate: Int, CaseIterable, Identifiable {
    case high = 240
    case medium = 120
    case low = 60

    static let minimumEffectiveHz = 30

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }

    var displayName: String { "\(title) (\(rawValue) Hz)" }

    static func effectiveHz(for savedHz: Int) -> Int {
        max(minimumEffectiveHz, savedHz)
    }

    static func displayName(for savedHz: Int) -> String {
        if let preset = Self(rawValue: savedHz) {
            return preset.displayName
        }

        let effective = effectiveHz(for: savedHz)
        if effective != savedHz {
            return "Custom (\(savedHz) Hz; effective \(effective) Hz)"
        }
        return "Custom (\(savedHz) Hz)"
    }
}
