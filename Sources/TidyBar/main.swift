/**
 * [INPUT]: 依赖 AppKit 与 AppDelegate
 * [OUTPUT]: 启动纯 AppKit NSApplication 主事件循环（accessory 无 Dock 图标模式）
 * [POS]: TidyBar 可执行入口点
 * [PROTOCOL]: Update this header on change, then check GEMINI.md
 */

import AppKit

// ============================================================================
// MARK: - 应用主入口
// ============================================================================

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
