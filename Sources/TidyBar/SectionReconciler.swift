/**
 * [INPUT]: 依赖 AppKit、TidyBarCore（MenuBarItemInfo、MenuBarSection、SettingsStore、SectionLayoutEngine、PermissionManager）与 MenuBarItemMover
 * [OUTPUT]: 提供 SectionReconciler（重启后分批归位、基于 NSWorkspace 启动通知的事件驱动单应用归位、显式选择记录与退出快照）
 * [POS]: TidyBar 的分区记忆与自动纠偏引擎，零后台轮询，保证重开机或第三方应用重启后菜单栏分区一致
 * [PROTOCOL]: Update this header on change, then check GEMINI.md
 */

import AppKit
import Foundation
import TidyBarCore

// ============================================================================
// MARK: - 分区记忆与自动归位协调器
// ============================================================================

@MainActor
final class SectionReconciler {
    struct ScanSnapshot {
        let items: [MenuBarItemInfo]
        let screenMaxX: CGFloat
        let menuBarCGMinY: CGFloat
    }

    private let settingsStore: SettingsStore
    private let canReconcileNow: () -> Bool
    private let scanCurrentItems: () -> ScanSnapshot?
    private let prepareDividers: () -> Void
    private let readDividerSnapshots: () -> (toggle: RawStatusWindow, hidden: RawStatusWindow, always: RawStatusWindow?)?
    private let afterReconcile: () -> Void

    private(set) var hasCompletedInitialPass = false
    private var hasScheduledStartup = false
    private var isReconciling = false

    nonisolated(unsafe) private var launchObserver: NSObjectProtocol?
    nonisolated(unsafe) private var pendingWorkItems: [DispatchWorkItem] = []

    init(
        settingsStore: SettingsStore,
        canReconcileNow: @escaping () -> Bool,
        scanCurrentItems: @escaping () -> ScanSnapshot?,
        prepareDividers: @escaping () -> Void,
        readDividerSnapshots: @escaping () -> (toggle: RawStatusWindow, hidden: RawStatusWindow, always: RawStatusWindow?)?,
        afterReconcile: @escaping () -> Void
    ) {
        self.settingsStore = settingsStore
        self.canReconcileNow = canReconcileNow
        self.scanCurrentItems = scanCurrentItems
        self.prepareDividers = prepareDividers
        self.readDividerSnapshots = readDividerSnapshots
        self.afterReconcile = afterReconcile
        registerLaunchObserver()
    }

    deinit {
        if let observer = launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        for work in pendingWorkItems {
            work.cancel()
        }
    }

    /// 记录用户在「图标管理」页显式选定的分区归属，供重启与重开应用后自动恢复
    func recordExplicitChoice(item: MenuBarItemInfo, section: MenuBarSection) {
        let key = item.stableKey
        guard !key.isEmpty else { return }
        settingsStore.update { $0.pinnedSections[key] = section }
    }

    /// 批量记录图标列表的目标分区（例如校准分割线后写入隐藏区规则）
    func recordBatchChoices(_ items: [MenuBarItemInfo], section: MenuBarSection) {
        guard !items.isEmpty else { return }
        settingsStore.update { settings in
            for item in items where !item.stableKey.isEmpty {
                settings.pinnedSections[item.stableKey] = section
            }
        }
    }

    /// 启动/开机后两段式归位：2.0s 处理首批状态项，7.5s 覆盖 Electron / 代理 / WPS 等慢启动登录项
    func scheduleStartupReconciliation() {
        guard !hasScheduledStartup else { return }
        hasScheduledStartup = true

        scheduleWork(after: 2.0) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.reconcile(targetPID: nil)
                self.hasCompletedInitialPass = true
            }
        }
        scheduleWork(after: 7.5) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.reconcile(targetPID: nil)
            }
        }
    }

    /// 对全屏或单个目标进程执行一次性分区纠偏（无漂移时零事件开销）
    func reconcile(targetPID: pid_t? = nil) async {
        guard PermissionManager.hasAccessibilityPermission else { return }
        let settings = settingsStore.settings
        guard !settings.pinnedSections.isEmpty else { return }
        guard !isReconciling, canReconcileNow() else { return }
        guard let snapshot = scanCurrentItems() else { return }

        let candidates: [MenuBarItemInfo]
        if let targetPID {
            candidates = snapshot.items.filter { $0.ownerPID == targetPID }
        } else {
            candidates = snapshot.items
        }

        let drifted = SectionLayoutEngine.computeDriftedItems(
            items: candidates,
            pinnedSections: settings.pinnedSections,
            enableAlwaysHiddenSection: settings.enableAlwaysHiddenSection,
            screenMaxX: snapshot.screenMaxX
        )
        guard !drifted.isEmpty else { return }

        isReconciling = true
        defer { isReconciling = false }

        for entry in drifted.prefix(12) {
            guard canReconcileNow() || targetPID != nil else { break }
            _ = await MenuBarItemMover.move(
                item: entry.item,
                to: entry.targetSection,
                menuBarCGMinY: snapshot.menuBarCGMinY,
                prepareDividers: prepareDividers,
                readDividerSnapshots: readDividerSnapshots
            )
            try? await Task.sleep(for: .milliseconds(30))
        }

        afterReconcile()
    }

    /// 将当前屏幕上全部可管理图标的所属分区合并写入持久化记忆（保留未运行应用的旧规则）
    @discardableResult
    func snapshotCurrentLayout(forceEvenIfUnreconciled: Bool) -> Int {
        if !forceEvenIfUnreconciled {
            guard PermissionManager.hasAccessibilityPermission, hasCompletedInitialPass else {
                return 0
            }
        }
        guard let snapshot = scanCurrentItems() else { return 0 }

        var capturedCount = 0
        settingsStore.update { settings in
            for item in snapshot.items {
                let isPinned = SectionLayoutEngine.isLikelySystemPinnedItem(
                    ownerName: item.ownerName,
                    title: item.title,
                    cgFrame: item.cgFrame,
                    screenMaxX: snapshot.screenMaxX
                )
                guard !isPinned, !item.stableKey.isEmpty else { continue }
                settings.pinnedSections[item.stableKey] = item.section
                capturedCount += 1
            }
        }
        return capturedCount
    }

    // MARK: - Private Event-Driven Helpers

    private func registerLaunchObserver() {
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let app else { return }
            let pid = app.processIdentifier
            let bundleID = app.bundleIdentifier
            let appName = app.localizedName
            Task { @MainActor [weak self] in
                self?.handleApplicationLaunch(pid: pid, bundleID: bundleID, appName: appName)
            }
        }
    }

    private func handleApplicationLaunch(pid: pid_t, bundleID: String?, appName: String?) {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        let pinned = settingsStore.settings.pinnedSections
        guard !pinned.isEmpty else { return }

        let prefixes = [bundleID, appName].compactMap { raw -> String? in
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        guard !prefixes.isEmpty else { return }

        let isTracked = pinned.keys.contains { key in
            prefixes.contains { prefix in
                key == prefix || key.hasPrefix("\(prefix)::")
            }
        }
        guard isTracked else { return }

        // 应用刚启动时 NSStatusItem 可能尚未注册窗口，延迟 1.8s 精确单进程归位
        scheduleWork(after: 1.8) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.reconcile(targetPID: pid)
            }
        }
    }

    private func scheduleWork(after seconds: TimeInterval, block: @escaping @MainActor () -> Void) {
        var workRef: DispatchWorkItem?
        let work = DispatchWorkItem { [weak self] in
            if let workRef {
                self?.pendingWorkItems.removeAll { $0 === workRef }
            }
            block()
        }
        workRef = work
        pendingWorkItems.append(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
