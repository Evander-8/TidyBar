/**
 * [INPUT]: 依赖 AppKit、TidyBarCore（SettingsStore、SectionLayoutEngine、PermissionManager、MenuBarMoveResult）与 StatusItemDefaults、MenuBarScanner、MenuBarItemMover、ClickForwarder、SectionReconciler、MenuBarContextMenuBuilder
 * [OUTPUT]: 提供 MenuBarController（管理三段式 NSStatusItem 位序创建与启动就绪折叠、无条件清图撑开隐藏、防自锁原子重建、重启/重开自动归位、单图标借位二级栏与右键菜单）
 * [POS]: TidyBar 核心常驻控制器，统一协调顶部状态栏折叠、分区自动纠偏、二级下拉栏展示与设置页图标重排
 * [PROTOCOL]: Update this header on change, then check GEMINI.md
 */

import AppKit
import TidyBarCore

// ============================================================================
// MARK: - 菜单栏主控制器
// ============================================================================

@MainActor
final class MenuBarController: NSObject {
    private enum Constants {
        static let collapsedSpacerLength: CGFloat = 10_000
        static let toggleLength: CGFloat = 24
        static let hiddenDividerLength: CGFloat = 10
        static let alwaysHiddenDividerLength: CGFloat = 12
        static let arrangeDividerLength: CGFloat = 16
    }

    private enum ExpansionState {
        case collapsed
        case inlineHiddenOnly
        case inlineAll
        case secondaryHiddenOnly
        case secondaryAll
    }

    private let settingsStore: SettingsStore
    private let onOpenSettings: (Int) -> Void
    private let secondaryPanel = SecondaryBarPanelController()
    private let clickForwarder = ClickForwarder()

    private var sectionReconciler: SectionReconciler!
    private var toggleItem: NSStatusItem!
    private var hiddenDividerItem: NSStatusItem!
    private var alwaysHiddenDividerItem: NSStatusItem?

    private var state: ExpansionState = .collapsed
    private var lastOrderIssue: DividerOrderValidation = .valid
    private var lastAppliedSettings: TidyBarSettings
    private var isPointerHoveringPanel = false
    private var hasAttemptedPositionRepair = false
    private var isRepairingOrder = false
    private var isBusyManaging = false

    private var autoRehideWorkItem: DispatchWorkItem?
    private var globalClickMonitor: Any?
    private var workspaceObserver: NSObjectProtocol?
    private var screenChangeObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    init(
        settingsStore: SettingsStore,
        onOpenSettings: @escaping (Int) -> Void
    ) {
        self.settingsStore = settingsStore
        self.onOpenSettings = onOpenSettings
        self.lastAppliedSettings = settingsStore.settings
        super.init()

        self.sectionReconciler = SectionReconciler(
            settingsStore: settingsStore,
            canReconcileNow: { [weak self] in
                guard let self else { return false }
                return self.state == .collapsed
                    && !self.isRepairingOrder
                    && !self.isBusyManaging
                    && !self.clickForwarder.hasTempShownItems
                    && NSEvent.pressedMouseButtons == 0
            },
            scanCurrentItems: { [weak self] in
                self?.scanReconcilerSnapshot()
            },
            prepareDividers: { [weak self] in
                self?.prepareDividersForRearrangement()
            },
            readDividerSnapshots: { [weak self] in
                self?.liveDividerSnapshots()
            },
            afterReconcile: { [weak self] in
                self?.collapse(force: false)
            }
        )

        setupStatusItems()
        wireSecondaryPanelCallbacks()
        registerEnvironmentObservers()

        settingsStore.addChangeListener { [weak self] _ in
            Task { @MainActor in
                self?.handleSettingsChanged()
            }
        }

        // 等待 macOS 将所有 NSStatusItem 放置出 (0, 0) 后再校验顺序并折叠
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.collapseAtLaunch(retriesLeft: 12)
        }
    }

    deinit {
        if let screenObs = screenChangeObserver {
            NotificationCenter.default.removeObserver(screenObs)
        }
        if let wakeObs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObs)
        }
    }

    // MARK: - Public Actions

    func toggleFromHotkey() {
        toggle(includeAlwaysHidden: NSEvent.modifierFlags.contains(.option))
    }

    func toggle(includeAlwaysHidden: Bool) {
        if state != .collapsed {
            collapse(force: true)
            return
        }
        expand(includeAlwaysHidden: includeAlwaysHidden)
    }

    func expand(includeAlwaysHidden: Bool) {
        switch settingsStore.settings.displayMode {
        case .inline:
            expandInline(includeAlwaysHidden: includeAlwaysHidden)
        case .secondaryBar:
            openSecondaryBar(includeAlwaysHidden: includeAlwaysHidden)
        }
    }

    func collapse(force: Bool = false) {
        secondaryPanel.hide()
        tearDownAutoRehideWatchers()
        isPointerHoveringPanel = false

        if clickForwarder.hasTempShownItems {
            Task { @MainActor [weak self] in
                await self?.clickForwarder.rehideTempShownItemsNow()
            }
        }

        guard let dividers = liveDividerCGFrames() else {
            if force {
                setDividerCollapsed(hiddenDividerItem, collapsed: false)
                alwaysHiddenDividerItem.map { setDividerCollapsed($0, collapsed: false) }
                state = .collapsed
                refreshArt()
            }
            return
        }

        let ctx = currentMenuBarContext()
        let validation = SectionLayoutEngine.validateDividerOrder(
            toggleFrame: dividers.toggle,
            hiddenDividerFrame: dividers.hidden,
            alwaysHiddenDividerFrame: dividers.always
        )
        let toggleOffScreen = SectionLayoutEngine.isToggleOffScreen(
            toggleCGFrame: dividers.toggle,
            screenCGFrame: ctx.screenCGFrame
        )
        lastOrderIssue = validation

        guard validation == .valid && !toggleOffScreen else {
            setDividerCollapsed(hiddenDividerItem, collapsed: false)
            alwaysHiddenDividerItem.map { setDividerCollapsed($0, collapsed: false) }
            state = .collapsed
            refreshArt()
            if !hasAttemptedPositionRepair && !isRepairingOrder {
                Task { @MainActor [weak self] in
                    await self?.repairInvertedDividerPositions(toggleOffScreen: toggleOffScreen)
                }
            }
            return
        }

        // 严格遵循 Ice / Hidden Bar：折叠态无条件清空分隔线图标、禁用高亮并撑开 10_000pt 推离屏幕
        setDividerCollapsed(hiddenDividerItem, collapsed: true)
        alwaysHiddenDividerItem.map { setDividerCollapsed($0, collapsed: true) }

        state = .collapsed
        refreshArt()
        sectionReconciler.scheduleStartupReconciliation()
    }

    /// 退出或关机前快照并收缩分割线，避免 macOS 持久化 10_000 撑开状态并在下次启动引发错位
    func resetDividersToCompact() {
        if state == .collapsed,
           !clickForwarder.hasTempShownItems,
           let dividers = liveDividerCGFrames(),
           SectionLayoutEngine.validateDividerOrder(
            toggleFrame: dividers.toggle,
            hiddenDividerFrame: dividers.hidden,
            alwaysHiddenDividerFrame: dividers.always
           ) == .valid {
            _ = sectionReconciler.snapshotCurrentLayout(forceEvenIfUnreconciled: false)
        }

        secondaryPanel.hide()
        tearDownAutoRehideWatchers()
        setDividerCollapsed(hiddenDividerItem, collapsed: false)
        alwaysHiddenDividerItem.map { setDividerCollapsed($0, collapsed: false) }
        state = .collapsed
        refreshArt()
    }

    // MARK: - Settings Icon Manager API

    func scanFullSnapshot() async -> FullMenuBarSnapshot {
        await clickForwarder.rehideTempShownItemsNow()
        let ctx = currentMenuBarContext()

        if let dividers = liveDividerCGFrames() {
            return MenuBarScanner.scanAllSections(
                menuBarCGMinY: ctx.cgMinY,
                screenMaxX: ctx.screenMaxX,
                toggleCGFrame: dividers.toggle,
                hiddenDividerCGFrame: dividers.hidden,
                alwaysHiddenDividerCGFrame: dividers.always
            )
        }

        return FullMenuBarSnapshot(
            visibleItems: [],
            hiddenItems: [],
            alwaysHiddenItems: [],
            driftedBetweenCount: 0,
            menuBarCGMinY: ctx.cgMinY,
            screenMaxX: ctx.screenMaxX
        )
    }

    func moveItem(_ item: MenuBarItemInfo, to targetSection: MenuBarSection) async -> MenuBarMoveResult {
        isBusyManaging = true
        defer { isBusyManaging = false }

        await clickForwarder.rehideTempShownItemsNow()
        secondaryPanel.hide()
        tearDownAutoRehideWatchers()

        let ctx = currentMenuBarContext()
        let result = await MenuBarItemMover.move(
            item: item,
            to: targetSection,
            menuBarCGMinY: ctx.cgMinY,
            prepareDividers: { [weak self] in
                self?.prepareDividersForRearrangement()
            },
            readDividerSnapshots: { [weak self] in
                self?.liveDividerSnapshots()
            }
        )

        if result == .moved {
            sectionReconciler.recordExplicitChoice(item: item, section: targetSection)
        }
        collapse(force: true)
        return result
    }

    func alignDividerNextToToggle() async -> MenuBarMoveResult {
        isBusyManaging = true
        defer { isBusyManaging = false }

        await clickForwarder.rehideTempShownItemsNow()
        secondaryPanel.hide()
        tearDownAutoRehideWatchers()

        let ctx = currentMenuBarContext()
        var alignedInfos: [MenuBarItemInfo] = []
        if let dividers = liveDividerCGFrames() {
            let drifted = SectionLayoutEngine.itemsBetweenHiddenDividerAndToggle(
                MenuBarScanner.readRawStatusWindows(),
                toggleCGFrame: dividers.toggle,
                hiddenDividerCGFrame: dividers.hidden,
                menuBarCGMinY: ctx.cgMinY,
                ownPID: ProcessInfo.processInfo.processIdentifier
            )
            var cache: [pid_t: String] = [:]
            alignedInfos = MenuBarScanner.enrichWithBundleIdentifiers(
                drifted.map {
                    MenuBarItemInfo(
                        windowID: $0.windowID,
                        ownerPID: $0.ownerPID,
                        ownerName: $0.ownerName,
                        title: $0.title,
                        cgFrame: $0.cgFrame,
                        section: .hidden,
                        isOnScreen: $0.isOnScreen
                    )
                },
                cache: &cache
            )
        }

        let result = await MenuBarItemMover.alignHiddenDividerNextToToggle(
            menuBarCGMinY: ctx.cgMinY,
            prepareDividers: { [weak self] in
                self?.prepareDividersForRearrangement()
            },
            readDividerSnapshots: { [weak self] in
                self?.liveDividerSnapshots()
            }
        )

        if result == .moved {
            sectionReconciler.recordBatchChoices(alignedInfos, section: .hidden)
        }
        collapse(force: true)
        return result
    }

    func saveCurrentLayoutRules() async -> Int {
        await clickForwarder.rehideTempShownItemsNow()
        return sectionReconciler.snapshotCurrentLayout(forceEvenIfUnreconciled: true)
    }

    // MARK: - Setup & Launch Sequence

    private func setupStatusItems() {
        let alwaysEnabled = settingsStore.settings.enableAlwaysHiddenSection
        StatusItemDefaults.sanitizeBeforeCreation(alwaysHiddenEnabled: alwaysEnabled)

        let statusBar = NSStatusBar.system

        toggleItem = statusBar.statusItem(withLength: Constants.toggleLength)
        toggleItem.autosaveName = StatusItemDefaults.AutosaveName.toggle
        toggleItem.isVisible = true
        if let button = toggleItem.button {
            button.target = self
            button.action = #selector(handleToggleButtonAction(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.toolTip = "TidyBar · 左键展开/收起 · Option+点击显示全部 · 右键菜单"
        }

        hiddenDividerItem = statusBar.statusItem(withLength: Constants.hiddenDividerLength)
        hiddenDividerItem.autosaveName = StatusItemDefaults.AutosaveName.hiddenDivider
        hiddenDividerItem.isVisible = true
        hiddenDividerItem.button?.toolTip = "TidyBar 隐藏分界线：左侧图标将被隐藏"

        syncAlwaysHiddenDividerItem()
        refreshArt()
    }

    private func syncAlwaysHiddenDividerItem() {
        let enabled = settingsStore.settings.enableAlwaysHiddenSection
        if enabled {
            if alwaysHiddenDividerItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: Constants.alwaysHiddenDividerLength)
                item.autosaveName = StatusItemDefaults.AutosaveName.alwaysHiddenDivider
                item.isVisible = true
                item.button?.toolTip = "TidyBar 总是隐藏分界线：左侧仅在 Option+点击时展开"
                alwaysHiddenDividerItem = item
            }
        } else if let existing = alwaysHiddenDividerItem {
            StatusItemDefaults.preservingPreferredPosition(for: StatusItemDefaults.AutosaveName.alwaysHiddenDivider) {
                NSStatusBar.system.removeStatusItem(existing)
            }
            alwaysHiddenDividerItem = nil
        }
    }

    private func collapseAtLaunch(retriesLeft: Int) {
        let togglePlaced = toggleItem.button?.window?.frame.origin != .zero
        let hiddenPlaced = hiddenDividerItem.button?.window?.frame.origin != .zero
        if (!togglePlaced || !hiddenPlaced || liveDividerCGFrames() == nil), retriesLeft > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.collapseAtLaunch(retriesLeft: retriesLeft - 1)
            }
            return
        }
        collapse(force: false)
    }

    private func wireSecondaryPanelCallbacks() {
        secondaryPanel.onSelectItem = { [weak self] info, isRightClick in
            Task { @MainActor in
                await self?.handleSecondaryItemSelection(info: info, isRightClick: isRightClick)
            }
        }
        secondaryPanel.onSwitchToInline = { [weak self] in
            self?.settingsStore.update { $0.displayMode = .inline }
            self?.expandInline(includeAlwaysHidden: false)
        }
        secondaryPanel.onRequestPermissions = { [weak self] in
            self?.secondaryPanel.hide()
            self?.onOpenSettings(4)
        }
        secondaryPanel.onManageIcons = { [weak self] in
            self?.secondaryPanel.hide()
            self?.onOpenSettings(0)
        }
        secondaryPanel.onHoverChanged = { [weak self] hovering in
            guard let self else { return }
            self.isPointerHoveringPanel = hovering
            if hovering {
                self.cancelAutoRehideTimer()
            } else if self.state != .collapsed {
                self.scheduleAutoRehideTimerIfNeeded()
            }
        }
        secondaryPanel.onDismissRequested = { [weak self] in
            self?.collapse(force: true)
        }
    }

    // MARK: - Expansion Flows

    private func expandInline(includeAlwaysHidden: Bool) {
        secondaryPanel.hide()
        if clickForwarder.hasTempShownItems {
            Task { @MainActor [weak self] in
                await self?.clickForwarder.rehideTempShownItemsNow()
            }
        }

        setDividerCollapsed(hiddenDividerItem, collapsed: false)
        let showAlways = includeAlwaysHidden && settingsStore.settings.enableAlwaysHiddenSection
        alwaysHiddenDividerItem.map { setDividerCollapsed($0, collapsed: !showAlways) }

        state = showAlways ? .inlineAll : .inlineHiddenOnly
        lastOrderIssue = .valid
        refreshArt()
        armAutoRehideWatchers()
    }

    private func openSecondaryBar(includeAlwaysHidden: Bool) {
        guard let dividers = liveDividerCGFrames(),
              let anchorRect = statusItemScreenFrame(toggleItem) else {
            expandInline(includeAlwaysHidden: includeAlwaysHidden)
            return
        }

        let validation = SectionLayoutEngine.validateDividerOrder(
            toggleFrame: dividers.toggle,
            hiddenDividerFrame: dividers.hidden,
            alwaysHiddenDividerFrame: dividers.always
        )
        lastOrderIssue = validation
        guard validation == .valid else {
            showContextMenu()
            return
        }

        let showAlways = includeAlwaysHidden && settingsStore.settings.enableAlwaysHiddenSection
        let maxColumns = settingsStore.settings.secondaryBarMaxColumns
        let menuBarCGMinY = currentMenuBarContext().cgMinY

        let result = MenuBarScanner.scanHiddenSync(
            menuBarCGMinY: menuBarCGMinY,
            hiddenDividerRightX: dividers.hidden.maxX,
            alwaysHiddenDividerRightX: dividers.always?.maxX,
            includeAlwaysHidden: showAlways
        )
        secondaryPanel.show(
            result: result,
            anchorRect: anchorRect,
            maxColumns: maxColumns,
            includeAlwaysHidden: showAlways
        )
        state = showAlways ? .secondaryAll : .secondaryHiddenOnly
        refreshArt()
        armAutoRehideWatchers()
    }

    private func handleSecondaryItemSelection(info: MenuBarItemInfo, isRightClick: Bool) async {
        secondaryPanel.hide()
        tearDownAutoRehideWatchers()

        guard let snaps = liveDividerSnapshots() else {
            collapse(force: true)
            return
        }

        let ctx = currentMenuBarContext()
        let outcome = await clickForwarder.forwardClick(
            to: info,
            isRightClick: isRightClick,
            menuBarCGMinY: ctx.cgMinY,
            screenCGFrame: ctx.screenCGFrame,
            auxiliaryTopLeft: ctx.auxiliaryTopLeft,
            auxiliaryTopRight: ctx.auxiliaryTopRight,
            toggleWindowID: snaps.toggle.windowID,
            toggleCGFrame: snaps.toggle.cgFrame,
            hiddenDividerWindowID: snaps.hidden.windowID,
            hiddenDividerCGFrame: snaps.hidden.cgFrame,
            alwaysHiddenDividerWindowID: snaps.always?.windowID,
            temporarilyReveal: { [weak self] section in
                guard let self else { return }
                self.setDividerCollapsed(self.hiddenDividerItem, collapsed: false)
                if section == .alwaysHidden {
                    self.alwaysHiddenDividerItem.map { self.setDividerCollapsed($0, collapsed: false) }
                    self.state = .inlineAll
                } else {
                    self.state = .inlineHiddenOnly
                }
                self.refreshArt()
            }
        )

        switch outcome {
        case .forwardedViaTempShow:
            state = .collapsed
            refreshArt()
        case .forwardedViaReveal:
            armPostClickAutoRehideWatchers(clickedPID: info.ownerPID)
        case .missingAccessibilityPermission:
            collapse(force: true)
            onOpenSettings(4)
        case .targetNotReachable:
            collapse(force: true)
        }
    }

    // MARK: - Actions & Context Menu

    @objc private func handleToggleButtonAction(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            toggle(includeAlwaysHidden: false)
            return
        }
        if event.modifierFlags.contains(.command) { return }

        if event.type == .rightMouseDown || event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
        } else {
            toggle(includeAlwaysHidden: event.modifierFlags.contains(.option))
        }
    }

    private func showContextMenu() {
        let driftedCount: Int
        if let dividers = liveDividerCGFrames() {
            driftedCount = SectionLayoutEngine.itemsBetweenHiddenDividerAndToggle(
                MenuBarScanner.readRawStatusWindows(),
                toggleCGFrame: dividers.toggle,
                hiddenDividerCGFrame: dividers.hidden,
                menuBarCGMinY: currentMenuBarContext().cgMinY,
                ownPID: ProcessInfo.processInfo.processIdentifier
            ).count
        } else {
            driftedCount = 0
        }

        let actions = MenuBarContextMenuBuilder.Actions(
            manageIcons: #selector(menuManageIcons),
            saveCurrentLayout: #selector(menuSaveCurrentLayout),
            alignDivider: #selector(menuAlignDivider),
            toggleHidden: #selector(menuToggleHidden),
            showAll: #selector(menuShowAll),
            selectDisplayMode: #selector(menuSelectDisplayMode(_:)),
            selectRehideDelay: #selector(menuSelectRehideDelay(_:)),
            toggleAlwaysHiddenSection: #selector(menuToggleAlwaysHiddenSection),
            openSettings: #selector(menuOpenSettings),
            quit: #selector(menuQuit)
        )
        let menu = MenuBarContextMenuBuilder.build(
            target: self,
            actions: actions,
            settings: settingsStore.settings,
            isCollapsed: state == .collapsed,
            lastOrderIssue: lastOrderIssue,
            driftedBetweenCount: driftedCount
        )
        if let button = toggleItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: button)
        }
    }

    @objc private func menuManageIcons() { onOpenSettings(0) }

    @objc private func menuSaveCurrentLayout() {
        Task { @MainActor in
            _ = await saveCurrentLayoutRules()
        }
    }

    @objc private func menuAlignDivider() {
        Task { @MainActor in
            let result = await alignDividerNextToToggle()
            if case .missingAccessibilityPermission = result {
                onOpenSettings(4)
            }
        }
    }

    @objc private func menuToggleHidden() { toggle(includeAlwaysHidden: false) }
    @objc private func menuShowAll() { expand(includeAlwaysHidden: true) }

    @objc private func menuSelectDisplayMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = DisplayMode(rawValue: raw) else { return }
        settingsStore.update { $0.displayMode = mode }
    }

    @objc private func menuSelectRehideDelay(_ sender: NSMenuItem) {
        guard let delay = AutoRehideDelay(rawValue: sender.tag) else { return }
        settingsStore.update { $0.autoRehideDelay = delay }
    }

    @objc private func menuToggleAlwaysHiddenSection() {
        settingsStore.update { $0.enableAlwaysHiddenSection.toggle() }
    }

    @objc private func menuOpenSettings() { onOpenSettings(1) }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: - Auto Rehide & Monitors

    private func armAutoRehideWatchers() {
        tearDownAutoRehideWatchers()
        scheduleAutoRehideTimerIfNeeded()

        let settings = settingsStore.settings
        guard settings.rehideOnFocusLoss || secondaryPanel.isVisible else { return }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state != .collapsed else { return }
                let mouseLoc = NSEvent.mouseLocation
                if let panelRect = self.secondaryPanel.panelFrame, panelRect.contains(mouseLoc) { return }
                if let toggleRect = self.statusItemScreenFrame(self.toggleItem)?.insetBy(dx: -12, dy: -4),
                   toggleRect.contains(mouseLoc) {
                    return
                }
                self.collapse(force: true)
            }
        }
        if settings.rehideOnFocusLoss {
            installActivationLossObserver(ignoringPID: nil)
        }
    }

    private func armPostClickAutoRehideWatchers(clickedPID: pid_t) {
        tearDownAutoRehideWatchers()
        scheduleAutoRehideTimerIfNeeded()

        let installTime = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.state != .collapsed else { return }
            self.globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.state != .collapsed else { return }
                    if Date().timeIntervalSince(installTime) < 0.35 { return }

                    let mouseLoc = NSEvent.mouseLocation
                    if let toggleRect = self.statusItemScreenFrame(self.toggleItem)?.insetBy(dx: -12, dy: -4),
                       toggleRect.contains(mouseLoc) {
                        return
                    }
                    if self.isPointInsideProcessWindow(mouseLoc: mouseLoc, pid: clickedPID) { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                        guard let self, self.state != .collapsed else { return }
                        self.collapse(force: true)
                    }
                }
            }
        }
        if settingsStore.settings.rehideOnFocusLoss {
            installActivationLossObserver(ignoringPID: clickedPID)
        }
    }

    private func installActivationLossObserver(ignoringPID: pid_t?) {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self, self.state != .collapsed else { return }
                let activatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let pid = activatedApp?.processIdentifier
                if pid == ProcessInfo.processInfo.processIdentifier || (ignoringPID != nil && pid == ignoringPID) {
                    return
                }
                self.collapse(force: true)
            }
        }
    }

    private func isPointInsideProcessWindow(mouseLoc: NSPoint, pid: pid_t) -> Bool {
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 900
        let cgPoint = CGPoint(x: mouseLoc.x, y: primaryHeight - mouseLoc.y)

        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return list.contains { entry in
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                return false
            }
            return bounds.contains(cgPoint)
        }
    }

    private func scheduleAutoRehideTimerIfNeeded() {
        cancelAutoRehideTimer()
        let seconds = settingsStore.settings.autoRehideDelay.rawValue
        guard seconds > 0, !isPointerHoveringPanel else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state != .collapsed, !self.isPointerHoveringPanel else { return }
            self.collapse(force: true)
        }
        autoRehideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
    }

    private func cancelAutoRehideTimer() {
        autoRehideWorkItem?.cancel()
        autoRehideWorkItem = nil
    }

    private func tearDownAutoRehideWatchers() {
        cancelAutoRehideTimer()
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }
    }

    // MARK: - Divider Helpers, Art & Self-Healing

    private func setDividerCollapsed(_ item: NSStatusItem, collapsed: Bool) {
        let isAlways = (item === alwaysHiddenDividerItem)
        let compactLength = isAlways ? Constants.alwaysHiddenDividerLength : Constants.hiddenDividerLength
        item.length = collapsed ? Constants.collapsedSpacerLength : compactLength
        item.button?.cell?.isEnabled = !collapsed
        if collapsed {
            item.button?.isHighlighted = false
            item.button?.image = nil
        }
    }

    private func prepareDividersForRearrangement() {
        hiddenDividerItem.length = Constants.arrangeDividerLength
        hiddenDividerItem.button?.cell?.isEnabled = true
        alwaysHiddenDividerItem?.length = Constants.arrangeDividerLength
        alwaysHiddenDividerItem?.button?.cell?.isEnabled = true
        refreshArt()
    }

    private func handleSettingsChanged() {
        let next = settingsStore.settings
        let prev = lastAppliedSettings
        lastAppliedSettings = next

        let structureChanged = prev.enableAlwaysHiddenSection != next.enableAlwaysHiddenSection
            || prev.displayMode != next.displayMode

        if structureChanged {
            syncAlwaysHiddenDividerItem()
            refreshArt()
            collapse(force: state != .collapsed)
        } else if prev.toggleIconStyle != next.toggleIconStyle || prev.dividerStyle != next.dividerStyle {
            refreshArt()
        }
    }

    private func refreshArt() {
        let settings = settingsStore.settings
        toggleItem.button?.image = StatusItemArt.toggleImage(
            style: settings.toggleIconStyle,
            isExpanded: state != .collapsed
        )

        if hiddenDividerItem.length < 500 {
            hiddenDividerItem.button?.image = StatusItemArt.dividerImage(
                style: settings.dividerStyle,
                isAlwaysHidden: false
            )
        } else {
            hiddenDividerItem.button?.image = nil
            hiddenDividerItem.button?.isHighlighted = false
        }

        if let always = alwaysHiddenDividerItem {
            if always.length < 500 {
                always.button?.image = StatusItemArt.dividerImage(
                    style: settings.dividerStyle,
                    isAlwaysHidden: true
                )
            } else {
                always.button?.image = nil
                always.button?.isHighlighted = false
            }
        }
    }

    private func statusItemScreenFrame(_ item: NSStatusItem) -> CGRect? {
        item.button?.window?.frame
    }

    private func scanReconcilerSnapshot() -> SectionReconciler.ScanSnapshot? {
        guard let dividers = liveDividerCGFrames() else { return nil }
        let ctx = currentMenuBarContext()
        let partitioned = SectionLayoutEngine.partitionItems(
            MenuBarScanner.readRawStatusWindows(),
            hiddenDividerRightX: dividers.hidden.maxX,
            alwaysHiddenDividerRightX: dividers.always?.maxX,
            ownPID: ProcessInfo.processInfo.processIdentifier,
            menuBarCGMinY: ctx.cgMinY
        )
        var cache: [pid_t: String] = [:]
        let combined = MenuBarScanner.enrichWithBundleIdentifiers(
            partitioned.visible + partitioned.hidden + partitioned.alwaysHidden,
            cache: &cache
        )
        return SectionReconciler.ScanSnapshot(
            items: combined,
            screenMaxX: ctx.screenMaxX,
            menuBarCGMinY: ctx.cgMinY
        )
    }

    private func currentMenuBarContext() -> (
        cgMinY: CGFloat,
        screenMaxX: CGFloat,
        screenCGFrame: CGRect,
        auxiliaryTopLeft: CGRect?,
        auxiliaryTopRight: CGRect?
    ) {
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 900
        let toggleScreen = statusItemScreenFrame(toggleItem).flatMap { frame in
            NSScreen.screens.first { $0.frame.intersects(frame) }
        } ?? NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main

        guard let screen = toggleScreen else {
            return (0, 1440, CGRect(x: 0, y: 0, width: 1440, height: 900), nil, nil)
        }
        let cgMinY = primaryHeight - screen.frame.maxY
        let screenCGFrame = CGRect(x: screen.frame.minX, y: cgMinY, width: screen.frame.width, height: screen.frame.height)
        return (cgMinY, screen.frame.maxX, screenCGFrame, screen.auxiliaryTopLeftArea, screen.auxiliaryTopRightArea)
    }

    private func liveDividerSnapshots() -> (toggle: RawStatusWindow, hidden: RawStatusWindow, always: RawStatusWindow?)? {
        guard let toggleID = statusItemWindowID(toggleItem),
              let hiddenID = statusItemWindowID(hiddenDividerItem) else {
            return nil
        }

        let ctx = currentMenuBarContext()
        let raw = MenuBarScanner.readRawStatusWindows()
        let alwaysID = alwaysHiddenDividerItem.flatMap { statusItemWindowID($0) }
        let classified = SectionLayoutEngine.classifyOwnStatusWindows(
            raw,
            ownPID: ProcessInfo.processInfo.processIdentifier,
            menuBarCGMinY: ctx.cgMinY,
            toggleWindowID: toggleID,
            hiddenDividerWindowID: hiddenID,
            alwaysHiddenDividerWindowID: alwaysID
        )

        if let toggleWin = classified.toggle, let hiddenWin = classified.hiddenDivider {
            let alwaysWin = (alwaysHiddenDividerItem != nil) ? classified.alwaysHiddenDivider : nil
            return (toggleWin, hiddenWin, alwaysWin)
        }

        guard let toggleAppKit = statusItemScreenFrame(toggleItem),
              let hiddenAppKit = statusItemScreenFrame(hiddenDividerItem) else {
            return nil
        }
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 900
        func makeSnapshot(id: CGWindowID, rect: CGRect) -> RawStatusWindow {
            let cgRect = CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
            return RawStatusWindow(
                windowID: id,
                ownerPID: ProcessInfo.processInfo.processIdentifier,
                ownerName: "TidyBar",
                title: "",
                cgFrame: cgRect,
                isOnScreen: true
            )
        }
        let alwaysSnap: RawStatusWindow? = {
            guard let item = alwaysHiddenDividerItem,
                  let id = statusItemWindowID(item),
                  let rect = statusItemScreenFrame(item) else { return nil }
            return makeSnapshot(id: id, rect: rect)
        }()
        return (makeSnapshot(id: toggleID, rect: toggleAppKit), makeSnapshot(id: hiddenID, rect: hiddenAppKit), alwaysSnap)
    }

    private func liveDividerCGFrames() -> (toggle: CGRect, hidden: CGRect, always: CGRect?)? {
        guard let snaps = liveDividerSnapshots() else { return nil }
        return (snaps.toggle.cgFrame, snaps.hidden.cgFrame, snaps.always?.cgFrame)
    }

    private func statusItemWindowID(_ item: NSStatusItem) -> CGWindowID? {
        guard let num = item.button?.window?.windowNumber, num > 0 else { return nil }
        return CGWindowID(num)
    }

    private func repairInvertedDividerPositions(toggleOffScreen: Bool) async {
        hasAttemptedPositionRepair = true
        isRepairingOrder = true
        defer { isRepairingOrder = false }

        if PermissionManager.hasAccessibilityPermission,
           !toggleOffScreen,
           let snaps = liveDividerSnapshots() {
            let enforced = await MenuBarItemMover.enforceDividerOrder(
                toggleWindowID: snaps.toggle.windowID,
                hiddenWindowID: snaps.hidden.windowID,
                alwaysWindowID: snaps.always?.windowID,
                ownPID: ProcessInfo.processInfo.processIdentifier
            )
            if enforced {
                try? await Task.sleep(for: .milliseconds(80))
                if let latest = liveDividerCGFrames(),
                   SectionLayoutEngine.validateDividerOrder(
                    toggleFrame: latest.toggle,
                    hiddenDividerFrame: latest.hidden,
                    alwaysHiddenDividerFrame: latest.always
                   ) == .valid {
                    collapse(force: false)
                    return
                }
            }
        }

        let statusBar = NSStatusBar.system
        if let always = alwaysHiddenDividerItem {
            statusBar.removeStatusItem(always)
            alwaysHiddenDividerItem = nil
        }
        statusBar.removeStatusItem(hiddenDividerItem)
        statusBar.removeStatusItem(toggleItem)

        StatusItemDefaults.resetToCleanOrder()
        setupStatusItems()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.collapseAtLaunch(retriesLeft: 10)
        }
    }

    private func registerEnvironmentObservers() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.hasAttemptedPositionRepair = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    guard let self, self.state == .collapsed else { return }
                    self.collapse(force: false)
                }
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.hasAttemptedPositionRepair = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, self.state == .collapsed else { return }
                    self.collapse(force: false)
                }
            }
        }
    }
}
