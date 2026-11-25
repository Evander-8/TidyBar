/**
 * [INPUT]: 依赖 AppKit（NSWorkspace）、ApplicationServices（AXIsProcessTrusted）、CoreGraphics（CGPreflightScreenCaptureAccess）
 * [OUTPUT]: 提供 PermissionManager 权限查询、按需授权请求与系统设置隐私面板跳转接口
 * [POS]: TidyBarCore 的隐私权限封装，确保启动静默检测且仅在用户主动操作时引导授权
 * [PROTOCOL]: Update this header on change, then check GEMINI.md
 */

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// ============================================================================
// MARK: - 系统权限管理
// ============================================================================

public enum PermissionManager {
    public static var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    public static func requestAccessibilityPermission(prompt: Bool = true) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public static func openScreenRecordingSettings() {
        openPrivacyPane(anchor: "Privacy_ScreenCapture")
    }

    public static func openAccessibilitySettings() {
        openPrivacyPane(anchor: "Privacy_Accessibility")
    }

    private static func openPrivacyPane(anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
