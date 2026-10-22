import AppKit
import Foundation

struct AppSetting: Codable, Equatable {
    var volume: Float = 1
    var muted = false

    var isUnity: Bool { volume == 1 && !muted }
}

struct AudioAppItem: Identifiable {
    let id: String
    let name: String
    let icon: NSImage
    let isPlaying: Bool
}

/// Persists per-app volumes, keyed by bundle identifier. Apps at 100% and unmuted are not stored.
enum SettingsStore {
    private static let appSettingsKey = "appSettings"
    private static let allowBoostKey = "allowBoost"

    static func loadAppSettings() -> [String: AppSetting] {
        guard let data = UserDefaults.standard.data(forKey: appSettingsKey),
              let settings = try? JSONDecoder().decode([String: AppSetting].self, from: data) else {
            return [:]
        }
        return settings
    }

    static func saveAppSettings(_ settings: [String: AppSetting]) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: appSettingsKey)
    }

    static var allowBoost: Bool {
        get { UserDefaults.standard.bool(forKey: allowBoostKey) }
        set { UserDefaults.standard.set(newValue, forKey: allowBoostKey) }
    }
}
