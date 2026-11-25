/**
 * [INPUT]: 依赖 Foundation（UserDefaults、JSONEncoder/JSONDecoder、NotificationCenter）与 Models.TidyBarSettings
 * [OUTPUT]: 提供 SettingsStore 单例与可注入实例，以及 tidyBarSettingsDidChange 通知名称
 * [POS]: TidyBarCore 的持久化配置中心，负责读取、修改、重置与广播用户偏好
 * [PROTOCOL]: Update this header on change, then check GEMINI.md
 */

import Foundation

public extension Notification.Name {
    static let tidyBarSettingsDidChange = Notification.Name("com.tidybar.settingsDidChange")
}

// ============================================================================
// MARK: - 配置持久化存储
// ============================================================================

public final class SettingsStore {
    public static let shared = SettingsStore()

    private static let storageKey = "com.tidybar.settings.v1"

    private let userDefaults: UserDefaults
    private var listeners: [UUID: (TidyBarSettings) -> Void] = [:]

    public private(set) var settings: TidyBarSettings

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.settings = Self.load(from: userDefaults)
    }

    public func update(_ transform: (inout TidyBarSettings) -> Void) {
        var next = settings
        transform(&next)
        next.secondaryBarMaxColumns = max(4, min(20, next.secondaryBarMaxColumns))
        guard next != settings else { return }
        settings = next
        save(next)
        notifyListeners(next)
    }

    public func resetToDefaults() {
        let defaults = TidyBarSettings.default
        guard defaults != settings else { return }
        settings = defaults
        save(defaults)
        notifyListeners(defaults)
    }

    @discardableResult
    public func addChangeListener(_ listener: @escaping (TidyBarSettings) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = listener
        return id
    }

    public func removeChangeListener(_ id: UUID) {
        listeners.removeValue(forKey: id)
    }

    // MARK: - Private Helpers

    private static func load(from defaults: UserDefaults) -> TidyBarSettings {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(TidyBarSettings.self, from: data) else {
            return .default
        }
        return decoded
    }

    private func save(_ value: TidyBarSettings) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }

    private func notifyListeners(_ value: TidyBarSettings) {
        for listener in listeners.values {
            listener(value)
        }
        NotificationCenter.default.post(name: .tidyBarSettingsDidChange, object: self)
    }
}
