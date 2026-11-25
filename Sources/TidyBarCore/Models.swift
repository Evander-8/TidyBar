/**
 * [INPUT]: 依赖 Foundation、AppKit（NSEvent.ModifierFlags）、Carbon（修饰键常量）、CoreGraphics（CGRect/CGWindowID）
 * [OUTPUT]: 提供 DisplayMode、ToggleIconStyle、DividerStyle、AutoRehideDelay、MenuBarSection、HotkeyCombo、MenuBarItemInfo 与 TidyBarSettings
 * [POS]: TidyBarCore 的核心领域模型层，为配置存储、布局引擎、扫描器与界面层提供统一契约
 * [PROTOCOL]: Update this header on change, then check GEMINI.md
 */

import AppKit
import Carbon
import CoreGraphics
import Foundation

// ============================================================================
// MARK: - 显示与外观枚举
// ============================================================================

public enum DisplayMode: String, Codable, CaseIterable, Sendable {
    case secondaryBar
    case inline

    public var displayTitle: String {
        switch self {
        case .secondaryBar: return "二级下拉栏"
        case .inline: return "菜单栏原地展开"
        }
    }

    public var subtitle: String {
        switch self {
        case .secondaryBar: return "点击时在菜单栏下方弹出悬浮面板，适合刘海屏或图标较多场景"
        case .inline: return "直接在顶部菜单栏收缩空白展开图标，零权限且最轻量"
        }
    }
}

public enum ToggleIconStyle: String, Codable, CaseIterable, Sendable {
    case chevron
    case dot
    case verticalBar
    case pill

    public var displayTitle: String {
        switch self {
        case .chevron: return "极简箭头"
        case .dot: return "圆点"
        case .verticalBar: return "竖线"
        case .pill: return "胶囊"
        }
    }
}

public enum DividerStyle: String, Codable, CaseIterable, Sendable {
    case line
    case dot
    case minimal

    public var displayTitle: String {
        switch self {
        case .line: return "细竖线"
        case .dot: return "微点"
        case .minimal: return "极简留白"
        }
    }
}

public enum AutoRehideDelay: Int, Codable, CaseIterable, Sendable {
    case off = 0
    case five = 5
    case ten = 10
    case fifteen = 15
    case thirty = 30

    public var displayTitle: String {
        switch self {
        case .off: return "关闭"
        case .five: return "5 秒"
        case .ten: return "10 秒"
        case .fifteen: return "15 秒"
        case .thirty: return "30 秒"
        }
    }
}

// ============================================================================
// MARK: - 菜单栏分区与状态图标实体
// ============================================================================

public enum MenuBarSection: String, Codable, Equatable, Sendable {
    case visible
    case hidden
    case alwaysHidden

    public var displayTitle: String {
        switch self {
        case .visible: return "常显区"
        case .hidden: return "隐藏区"
        case .alwaysHidden: return "总是隐藏区"
        }
    }
}

public struct MenuBarItemInfo: Equatable, Sendable {
    public let windowID: CGWindowID
    public let ownerPID: pid_t
    public let ownerName: String
    public let title: String
    public let cgFrame: CGRect
    public let section: MenuBarSection
    public let isOnScreen: Bool

    public init(
        windowID: CGWindowID,
        ownerPID: pid_t,
        ownerName: String,
        title: String,
        cgFrame: CGRect,
        section: MenuBarSection,
        isOnScreen: Bool
    ) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.title = title
        self.cgFrame = cgFrame
        self.section = section
        self.isOnScreen = isOnScreen
    }

    public var displayLabel: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty, trimmedTitle != ownerName {
            return "\(ownerName) - \(trimmedTitle)"
        }
        return ownerName.isEmpty ? "未命名状态图标" : ownerName
    }
}

// ============================================================================
// MARK: - 全局快捷键模型
// ============================================================================

public struct HotkeyCombo: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var displayString: String

    public init(keyCode: UInt32, modifiers: UInt32, displayString: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.displayString = displayString
    }

    /// 默认使用 Control + Option + H，避免与系统全局隐藏窗口快捷键 Command + H 冲突
    public static let defaultToggle = HotkeyCombo(
        keyCode: 4,
        modifiers: UInt32(controlKey | optionKey),
        displayString: formatDisplayString(keyCode: 4, modifiers: UInt32(controlKey | optionKey))
    )

    public static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    public static func formatDisplayString(keyCode: UInt32, modifiers: UInt32) -> String {
        var prefix = ""
        if modifiers & UInt32(controlKey) != 0 { prefix += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { prefix += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { prefix += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { prefix += "⌘" }
        return prefix + keyDisplayName(for: keyCode)
    }

    public static func keyDisplayName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_Grave: return "`"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return "Key(\(keyCode))"
        }
    }
}

// ============================================================================
// MARK: - 图标移动结果与持久化配置实体
// ============================================================================

public enum MenuBarMoveResult: Equatable, Sendable {
    case moved
    case missingAccessibilityPermission
    case immovableSystemItem
    case dividerOrderInvalid
    case failed(String)
}

public struct TidyBarSettings: Codable, Equatable, Sendable {
    public var displayMode: DisplayMode
    public var autoRehideDelay: AutoRehideDelay
    public var rehideOnFocusLoss: Bool
    public var enableAlwaysHiddenSection: Bool
    public var toggleIconStyle: ToggleIconStyle
    public var dividerStyle: DividerStyle
    public var hotkeyEnabled: Bool
    public var toggleHotkey: HotkeyCombo
    public var secondaryBarMaxColumns: Int
    public var hasOpenedInitialSettings: Bool

    public init(
        displayMode: DisplayMode = .secondaryBar,
        autoRehideDelay: AutoRehideDelay = .ten,
        rehideOnFocusLoss: Bool = true,
        enableAlwaysHiddenSection: Bool = true,
        toggleIconStyle: ToggleIconStyle = .chevron,
        dividerStyle: DividerStyle = .line,
        hotkeyEnabled: Bool = true,
        toggleHotkey: HotkeyCombo = .defaultToggle,
        secondaryBarMaxColumns: Int = 12,
        hasOpenedInitialSettings: Bool = false
    ) {
        self.displayMode = displayMode
        self.autoRehideDelay = autoRehideDelay
        self.rehideOnFocusLoss = rehideOnFocusLoss
        self.enableAlwaysHiddenSection = enableAlwaysHiddenSection
        self.toggleIconStyle = toggleIconStyle
        self.dividerStyle = dividerStyle
        self.hotkeyEnabled = hotkeyEnabled
        self.toggleHotkey = toggleHotkey
        self.secondaryBarMaxColumns = max(4, min(20, secondaryBarMaxColumns))
        self.hasOpenedInitialSettings = hasOpenedInitialSettings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let def = TidyBarSettings.default
        displayMode = try container.decodeIfPresent(DisplayMode.self, forKey: .displayMode) ?? def.displayMode
        autoRehideDelay = try container.decodeIfPresent(AutoRehideDelay.self, forKey: .autoRehideDelay) ?? def.autoRehideDelay
        rehideOnFocusLoss = try container.decodeIfPresent(Bool.self, forKey: .rehideOnFocusLoss) ?? def.rehideOnFocusLoss
        enableAlwaysHiddenSection = try container.decodeIfPresent(Bool.self, forKey: .enableAlwaysHiddenSection) ?? def.enableAlwaysHiddenSection
        toggleIconStyle = try container.decodeIfPresent(ToggleIconStyle.self, forKey: .toggleIconStyle) ?? def.toggleIconStyle
        dividerStyle = try container.decodeIfPresent(DividerStyle.self, forKey: .dividerStyle) ?? def.dividerStyle
        hotkeyEnabled = try container.decodeIfPresent(Bool.self, forKey: .hotkeyEnabled) ?? def.hotkeyEnabled
        toggleHotkey = try container.decodeIfPresent(HotkeyCombo.self, forKey: .toggleHotkey) ?? def.toggleHotkey
        let cols = try container.decodeIfPresent(Int.self, forKey: .secondaryBarMaxColumns) ?? def.secondaryBarMaxColumns
        secondaryBarMaxColumns = max(4, min(20, cols))
        hasOpenedInitialSettings = try container.decodeIfPresent(Bool.self, forKey: .hasOpenedInitialSettings) ?? true
    }

    public static let `default` = TidyBarSettings()
}
