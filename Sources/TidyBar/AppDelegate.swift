/**
 * [INPUT]: 依赖 AppKit、TidyBarCore（SettingsStore、HotkeyManager）与 MenuBarController、SettingsWindowController
 * [OUTPUT]: 提供 AppDelegate 应用生命周期协调器（单实例防重、状态栏与热键装配、首次启动引导弹窗）
 * [POS]: TidyBar 应用壳核心代理，负责串联无界面核心与 AppKit 界面层
 * [PROTOCOL]: Update this header on change, then check GEMINI.md
 */

import AppKit
import TidyBarCore

// ============================================================================
// MARK: - 应用生命周期代理
// ============================================================================

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore = SettingsStore.shared
    private let hotkeyManager = HotkeyManager()

    private var menuBarController: MenuBarController?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if terminateIfDuplicateInstanceRunning() {
            return
        }

        let settingsWC = SettingsWindowController(
            settingsStore: settingsStore,
            hotkeyManager: hotkeyManager
        )
        settingsWindowController = settingsWC

        let mbController = MenuBarController(settingsStore: settingsStore) { tab in
            settingsWC.show(tab: tab)
        }
        menuBarController = mbController

        settingsWC.menuBarActions = MenuBarActions(
            scanAll: { [weak mbController] in
                guard let mbController else {
                    return FullMenuBarSnapshot(
                        visibleItems: [],
                        hiddenItems: [],
                        alwaysHiddenItems: [],
                        driftedBetweenCount: 0,
                        menuBarCGMinY: 0,
                        screenMaxX: 1440
                    )
                }
                return await mbController.scanFullSnapshot()
            },
            moveItem: { [weak mbController] item, section in
                guard let mbController else {
                    return .failed("菜单栏控制器不可用")
                }
                return await mbController.moveItem(item, to: section)
            },
            alignDivider: { [weak mbController] in
                guard let mbController else {
                    return .failed("菜单栏控制器不可用")
                }
                return await mbController.alignDividerNextToToggle()
            }
        )

        hotkeyManager.onTrigger = { [weak mbController] in
            mbController?.toggleFromHotkey()
        }
        var lastHotkeySettings = settingsStore.settings
        applyHotkeySettings(lastHotkeySettings)

        settingsStore.addChangeListener { [weak self] next in
            Task { @MainActor in
                guard next.hotkeyEnabled != lastHotkeySettings.hotkeyEnabled
                    || next.toggleHotkey != lastHotkeySettings.toggleHotkey else {
                    lastHotkeySettings = next
                    return
                }
                lastHotkeySettings = next
                self?.applyHotkeySettings(next)
            }
        }

        // 首次启动自动打开「图标管理」页，让用户直接勾选要隐藏的图标
        if !settingsStore.settings.hasOpenedInitialSettings {
            settingsStore.update { $0.hasOpenedInitialSettings = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak settingsWC] in
                settingsWC?.show(tab: 0)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindowController?.show(tab: 0)
        return true
    }

    // MARK: - Private Helpers

    private func applyHotkeySettings(_ settings: TidyBarSettings) {
        if settings.hotkeyEnabled {
            _ = hotkeyManager.register(combo: settings.toggleHotkey)
        } else {
            hotkeyManager.unregister()
        }
    }

    private func terminateIfDuplicateInstanceRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let duplicates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != currentPID }

        guard let existing = duplicates.first else { return false }
        existing.activate()
        NSApp.terminate(nil)
        return true
    }
}
