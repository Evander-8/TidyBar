/**
 * [INPUT]: 依赖 Foundation 与 TidyBarCore.SectionLayoutEngine
 * [OUTPUT]: 提供 StatusItemDefaults（管理 NSStatusItem Preferred Position / Visible 启动前自愈、原子重置与移除时位置保护）
 * [POS]: TidyBar 状态栏位置持久化守护者，参考 Ice 与 Hidden Bar 在创建 NSStatusItem 前确保顺序合法
 * [PROTOCOL]: Update this header on change, then check GEMINI.md
 */

import Foundation
import TidyBarCore

// ============================================================================
// MARK: - NSStatusItem 持久化位置读写与启动自愈
// ============================================================================

enum StatusItemDefaults {
    enum AutosaveName {
        static let toggle = "TidyBar.toggle"
        static let hiddenDivider = "TidyBar.hiddenDivider"
        static let alwaysHiddenDivider = "TidyBar.alwaysHiddenDivider"

        static let all = [toggle, hiddenDivider, alwaysHiddenDivider]
    }

    private static func preferredPositionKey(for autosaveName: String) -> String {
        "NSStatusItem Preferred Position \(autosaveName)"
    }

    private static func visibleKey(for autosaveName: String) -> String {
        "NSStatusItem Visible \(autosaveName)"
    }

    static func preferredPosition(for autosaveName: String, defaults: UserDefaults = .standard) -> Double? {
        guard let number = defaults.object(forKey: preferredPositionKey(for: autosaveName)) as? NSNumber else {
            return nil
        }
        return number.doubleValue
    }

    static func setPreferredPosition(_ value: Double?, for autosaveName: String, defaults: UserDefaults = .standard) {
        let key = preferredPositionKey(for: autosaveName)
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    static func setVisible(_ visible: Bool, for autosaveName: String, defaults: UserDefaults = .standard) {
        defaults.set(visible, forKey: visibleKey(for: autosaveName))
    }

    /// 在创建 NSStatusItem 之前校验并修复 UserDefaults 中持久化的位置，彻底杜绝倒置或自锁
    /// 注意 macOS 从右向左计位：0 在最右，1 在其紧邻左侧，nil 则交由系统置于最左。
    static func sanitizeBeforeCreation(alwaysHiddenEnabled: Bool, defaults: UserDefaults = .standard) {
        let togglePos = preferredPosition(for: AutosaveName.toggle, defaults: defaults)
        let hiddenPos = preferredPosition(for: AutosaveName.hiddenDivider, defaults: defaults)
        let alwaysPos = alwaysHiddenEnabled
            ? preferredPosition(for: AutosaveName.alwaysHiddenDivider, defaults: defaults)
            : nil

        if !SectionLayoutEngine.arePreferredPositionsOrdered(
            togglePos: togglePos,
            hiddenPos: hiddenPos,
            alwaysPos: alwaysPos
        ) {
            resetToCleanOrder(defaults: defaults)
            return
        }

        setVisible(true, for: AutosaveName.toggle, defaults: defaults)
        setVisible(true, for: AutosaveName.hiddenDivider, defaults: defaults)
        if alwaysHiddenEnabled {
            setVisible(true, for: AutosaveName.alwaysHiddenDivider, defaults: defaults)
        }
    }

    /// 清空异常位置并将主开关与分割线重置为 Ice 风格的干净初始位序（toggle=0, hidden=1, always=nil）
    static func resetToCleanOrder(defaults: UserDefaults = .standard) {
        for name in AutosaveName.all {
            defaults.removeObject(forKey: preferredPositionKey(for: name))
            defaults.removeObject(forKey: visibleKey(for: name))
        }
        setPreferredPosition(0, for: AutosaveName.toggle, defaults: defaults)
        setPreferredPosition(1, for: AutosaveName.hiddenDivider, defaults: defaults)
        setVisible(true, for: AutosaveName.toggle, defaults: defaults)
        setVisible(true, for: AutosaveName.hiddenDivider, defaults: defaults)
        // alwaysHidden 留空（nil），由 macOS 放置在更左侧，确保已有应用先落入普通隐藏区
        defaults.synchronize()
    }

    /// 执行移除或隐藏 NSStatusItem 等会抹除 Preferred Position 的操作前后，自动保留原位置
    static func preservingPreferredPosition(
        for autosaveName: String,
        defaults: UserDefaults = .standard,
        body: () -> Void
    ) {
        let cached = preferredPosition(for: autosaveName, defaults: defaults)
        body()
        if let cached {
            setPreferredPosition(cached, for: autosaveName, defaults: defaults)
        }
    }
}
