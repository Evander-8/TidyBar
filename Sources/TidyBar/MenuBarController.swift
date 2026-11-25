/**
 * [INPUT]: 依赖 AppKit、TidyBarCore（SettingsStore、SectionLayoutEngine、PermissionManager、MenuBarMoveResult）与视觉/扫描/移动/转发组件
 * [OUTPUT]: 提供 MenuBarController（管理三段式 NSStatusItem、防自锁折叠、空分区不自藏分割线、可视化移动协调与右键菜单）
 * [POS]: TidyBar 的核心常驻控制器，既驱动顶部状态栏折叠与二级下拉栏，也为设置窗口提供图标扫描与重排入口
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

    private var toggleItem: NSStatusItem!
    private var hiddenDividerItem: NSStatusItem!
    private var alwaysHiddenDividerItem: NSStatusItem?

    private let secondaryPanel = SecondaryBarPanelController()

    private var state: ExpansionState = .collapsed
    private var lastOrderIssue: DividerOrderValidation = .valid
    private var lastAppliedSettings: TidyBarSettings
    private var isPointerHoveringPanel = false

    // 自动收起与失焦监听仅在展开期间存在，收起后立即销毁，保证空闲 0% CPU
    private var autoRehideWorkItem: DispatchWorkItem?
    private var globalClickMonitor: Any?
    private var workspaceObserver: NSObjectProtocol?

    init(
        settingsStore: SettingsStore,
        onOpenSettings: @escaping (Int) -> Void
    ) {
        self.settingsStore = settingsStore
        self.onOpenSettings = onOpenSettings
        self.lastAppliedSettings = settingsStore.settings
        super.init()

        setupStatusItems()
        wireSecondaryPanelCallbacks()

        settingsStore.addChangeListener { [weak self] _ in
            Task { @MainActor in
                self?.handleSettingsChanged()
            }
        }

        // 延迟 0.35s 待 macOS 完成 NSStatusItem 初始布局后校验顺序并默认折叠
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.collapse(force: false)
        }
    }

    // MARK: - Public Actions

    func toggleFromHotkey() {
        let includeAlwaysHidden = NSEvent.modifierFlags.contains(.option)
        toggle(includeAlwaysHidden: includeAlwaysHidden)
    }

    func toggle(includeAlwaysHidden: Bool) {
        if state != .collapsed {
            collapse(force: true)
            return
        }
        expand(includeAlwaysHidden: includeAlwaysHidden)
    }

    func expand(includeAlwaysHidden: Bool) {
        let settings = settingsStore.settings
        switch settings.displayMode {
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

        guard let dividers = liveDividerCGFrames() else {
            if force {
                hiddenDividerItem.length = Constants.hiddenDividerLength
                alwaysHiddenDividerItem?.length = Constants.alwaysHiddenDividerLength
                state = .collapsed
                refreshArt()
            }
            return
        }

        let validation = SectionLayoutEngine.validateDividerOrder(
            toggleFrame: dividers.toggle,
            hiddenDividerFrame: dividers.hidden,
            alwaysHiddenDividerFrame: dividers.always
        )
        lastOrderIssue = validation

        guard validation == .valid else {
            // 防自锁：分割线顺序异常时绝不撑开 10_000 宽度，防止将主按钮推出屏幕
            hiddenDividerItem.length = Constants.hiddenDividerLength
            alwaysHiddenDividerItem?.length = Constants.alwaysHiddenDividerLength
            state = .collapsed
            refreshArt()
            return
        }

        // 只有当分区内确实存在图标时才撑开 10_000 宽度将其推离屏幕；
        // 若分区为空，则保持紧凑可见分割线，方便用户识别边界与拖动。
        let partitioned = SectionLayoutEngine.partitionItems(
            MenuBarScanner.readRawStatusWindows(),
            hiddenDividerRightX: dividers.hidden.maxX,
            alwaysHiddenDividerRightX: dividers.always?.maxX,
            ownPID: ProcessInfo.processInfo.processIdentifier,
            menuBarCGMinY: currentMenuBarContext().cgMinY
        )

        hiddenDividerItem.length = (!partitioned.hidden.isEmpty || !partitioned.alwaysHidden.isEmpty)
            ? Constants.collapsedSpacerLength
            : Constants.hiddenDividerLength

        alwaysHiddenDividerItem?.length = !partitioned.alwaysHidden.isEmpty
            ? Constants.collapsedSpacerLength
            : Constants.alwaysHiddenDividerLength

        state = .collapsed
        refreshArt()
    }

    // MARK: - Settings Icon Manager API

    func scanFullSnapshot() async -> FullMenuBarSnapshot {
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

        collapse(force: true)
        return result
    }

    func alignDividerNextToToggle() async -> MenuBarMoveResult {
        secondaryPanel.hide()
        tearDownAutoRehideWatchers()

        let ctx = currentMenuBarContext()
        let result = await MenuBarItemMover.alignHiddenDividerNextToToggle(
            menuBarCGMinY: ctx.cgMinY,
            prepareDividers: { [weak self] in
                self?.prepareDividersForRearrangement()
            },
            readDividerSnapshots: { [weak self] in
                self?.liveDividerSnapshots()
            }
        )

        collapse(force: true)
        return result
    }

    // MARK: - Setup

    private func setupStatusItems() {
        let statusBar = NSStatusBar.system

        // 1. 严格先创建主按钮（位于最右侧）
        toggleItem = statusBar.statusItem(withLength: Constants.toggleLength)
        toggleItem.autosaveName = "TidyBar.toggle"
        if let button = toggleItem.button {
            button.target = self
            button.action = #selector(handleToggleButtonAction(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.toolTip = "TidyBar · 左键展开/收起 · Option+点击显示全部 · 右键菜单"
        }

        // 2. 创建普通隐藏分割线（位于主按钮左侧）
        hiddenDividerItem = statusBar.statusItem(withLength: Constants.hiddenDividerLength)
        hiddenDividerItem.autosaveName = "TidyBar.hiddenDivider"
        hiddenDividerItem.button?.toolTip = "TidyBar 隐藏分界线：左侧图标将被隐藏（也可在设置中一键选择）"
        hiddenDividerItem.button?.isEnabled = false

        // 3. 按配置创建「总是隐藏」分割线（位于普通隐藏分割线更左侧）
        syncAlwaysHiddenDividerItem()
        refreshArt()
    }

    private func syncAlwaysHiddenDividerItem() {
        let enabled = settingsStore.settings.enableAlwaysHiddenSection
        if enabled {
            if alwaysHiddenDividerItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: Constants.alwaysHiddenDividerLength)
                item.autosaveName = "TidyBar.alwaysHiddenDivider"
                item.button?.toolTip = "TidyBar 总是隐藏分界线：左侧仅在 Option+点击时展开"
                item.button?.isEnabled = false
                alwaysHiddenDividerItem = item
            }
        } else if let existing = alwaysHiddenDividerItem {
            NSStatusBar.system.removeStatusItem(existing)
            alwaysHiddenDividerItem = nil
        }
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
        hiddenDividerItem.length = Constants.hiddenDividerLength

        let showAlways = includeAlwaysHidden && settingsStore.settings.enableAlwaysHiddenSection
        alwaysHiddenDividerItem?.length = showAlways
            ? Constants.alwaysHiddenDividerLength
            : Constants.collapsedSpacerLength

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
        let hiddenRightX = dividers.hidden.maxX
        let alwaysRightX = dividers.always?.maxX
        let maxColumns = settingsStore.settings.secondaryBarMaxColumns
        let menuBarCGMinY = currentMenuBarContext().cgMinY

        // 纯同步扫描并即时弹出二级下拉栏，确保单击第一下零延迟响应
        let result = MenuBarScanner.scanHiddenSync(
            menuBarCGMinY: menuBarCGMinY,
            hiddenDividerRightX: hiddenRightX,
            alwaysHiddenDividerRightX: alwaysRightX,
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

        let ctx = currentMenuBarContext()
        let outcome = await ClickForwarder.forwardClick(
            to: info,
            isRightClick: isRightClick,
            menuBarCGMinY: ctx.cgMinY,
            screenCGFrame: ctx.screenCGFrame,
            auxiliaryTopLeft: ctx.auxiliaryTopLeft,
            auxiliaryTopRight: ctx.auxiliaryTopRight,
            temporarilyReveal: { [weak self] section in
                guard let self else { return }
                self.hiddenDividerItem.length = Constants.hiddenDividerLength
                if section == .alwaysHidden {
                    self.alwaysHiddenDividerItem?.length = Constants.alwaysHiddenDividerLength
                    self.state = .inlineAll
                } else {
                    self.state = .inlineHiddenOnly
                }
                self.refreshArt()
            }
        )

        switch outcome {
        case .forwarded:
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

        // 按住 Command 键时保留给 macOS 原生菜单栏拖动排序
        if event.modifierFlags.contains(.command) {
            return
        }

        if event.type == .rightMouseDown || event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
        } else {
            let includeAlways = event.modifierFlags.contains(.option)
            toggle(includeAlwaysHidden: includeAlways)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let settings = settingsStore.settings

        if lastOrderIssue != .valid {
            let warningText: String
            switch lastOrderIssue {
            case .hiddenDividerRightOfToggle:
                warningText = "⚠️ 请按住 ⌘ 将「|」分割线拖到主按钮左侧"
            case .alwaysHiddenDividerRightOfHidden:
                warningText = "⚠️ 请按住 ⌘ 将「‖」拖到「|」左侧"
            case .valid:
                warningText = ""
            }
            let warnItem = NSMenuItem(title: warningText, action: nil, keyEquivalent: "")
            warnItem.isEnabled = false
            menu.addItem(warnItem)
            menu.addItem(.separator())
        }

        let manageItem = NSMenuItem(title: "管理隐藏图标…", action: #selector(menuManageIcons), keyEquivalent: "")
        manageItem.target = self
        menu.addItem(manageItem)

        if let dividers = liveDividerCGFrames() {
            let drifted = SectionLayoutEngine.itemsBetweenHiddenDividerAndToggle(
                MenuBarScanner.readRawStatusWindows(),
                toggleCGFrame: dividers.toggle,
                hiddenDividerCGFrame: dividers.hidden,
                menuBarCGMinY: currentMenuBarContext().cgMinY,
                ownPID: ProcessInfo.processInfo.processIdentifier
            )
            if !drifted.isEmpty {
                let alignItem = NSMenuItem(
                    title: "校准分割线（隐藏中间 \(drifted.count) 个图标）",
                    action: #selector(menuAlignDivider),
                    keyEquivalent: ""
                )
                alignItem.target = self
                menu.addItem(alignItem)
            }
        }

        menu.addItem(.separator())

        let isCollapsed = state == .collapsed
        let toggleTitle = isCollapsed
            ? "展开隐藏区 (\(settings.toggleHotkey.displayString))"
            : "收起隐藏区 (\(settings.toggleHotkey.displayString))"
        let toggleMenuItem = NSMenuItem(title: toggleTitle, action: #selector(menuToggleHidden), keyEquivalent: "")
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        if settings.enableAlwaysHiddenSection {
            let showAllItem = NSMenuItem(title: "显示全部图标（含总是隐藏区）", action: #selector(menuShowAll), keyEquivalent: "")
            showAllItem.target = self
            menu.addItem(showAllItem)
        }

        menu.addItem(.separator())

        let modeMenu = NSMenu()
        for mode in DisplayMode.allCases {
            let item = NSMenuItem(title: mode.displayTitle, action: #selector(menuSelectDisplayMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = settings.displayMode == mode ? .on : .off
            modeMenu.addItem(item)
        }
        let modeParent = NSMenuItem(title: "显示模式：\(settings.displayMode.displayTitle)", action: nil, keyEquivalent: "")
        modeParent.submenu = modeMenu
        menu.addItem(modeParent)

        let rehideMenu = NSMenu()
        for delay in AutoRehideDelay.allCases {
            let item = NSMenuItem(title: delay.displayTitle, action: #selector(menuSelectRehideDelay(_:)), keyEquivalent: "")
            item.target = self
            item.tag = delay.rawValue
            item.state = settings.autoRehideDelay == delay ? .on : .off
            rehideMenu.addItem(item)
        }
        let rehideParent = NSMenuItem(title: "自动重新收起：\(settings.autoRehideDelay.displayTitle)", action: nil, keyEquivalent: "")
        rehideParent.submenu = rehideMenu
        menu.addItem(rehideParent)

        let alwaysSectionItem = NSMenuItem(
            title: "启用「总是隐藏区」(‖)",
            action: #selector(menuToggleAlwaysHiddenSection),
            keyEquivalent: ""
        )
        alwaysSectionItem.target = self
        alwaysSectionItem.state = settings.enableAlwaysHiddenSection ? .on : .off
        menu.addItem(alwaysSectionItem)

        menu.addItem(.separator())

        let prefsItem = NSMenuItem(title: "偏好设置…", action: #selector(menuOpenSettings), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        let quitItem = NSMenuItem(title: "退出 TidyBar", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        toggleItem.menu = menu
        toggleItem.button?.performClick(nil)
        toggleItem.menu = nil
    }

    @objc private func menuManageIcons() {
        onOpenSettings(0)
    }

    @objc private func menuAlignDivider() {
        Task { @MainActor in
            let result = await alignDividerNextToToggle()
            if case .missingAccessibilityPermission = result {
                onOpenSettings(4)
            }
        }
    }

    @objc private func menuToggleHidden() {
        toggle(includeAlwaysHidden: false)
    }

    @objc private func menuShowAll() {
        expand(includeAlwaysHidden: true)
    }

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

    @objc private func menuOpenSettings() {
        onOpenSettings(1)
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - Auto Rehide & Monitors (Zero Idle Overhead)

    private func armAutoRehideWatchers() {
        tearDownAutoRehideWatchers()
        scheduleAutoRehideTimerIfNeeded()

        let settings = settingsStore.settings
        guard settings.rehideOnFocusLoss || secondaryPanel.isVisible else { return }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state != .collapsed else { return }
                let mouseLoc = NSEvent.mouseLocation
                if let panelRect = self.secondaryPanel.panelFrame, panelRect.contains(mouseLoc) {
                    return
                }
                if let toggleRect = self.statusItemScreenFrame(self.toggleItem)?.insetBy(dx: -12, dy: -4),
                   toggleRect.contains(mouseLoc) {
                    return
                }
                self.collapse(force: true)
            }
        }

        if settings.rehideOnFocusLoss {
            workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in
                    guard let self, self.state != .collapsed else { return }
                    let activatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    if activatedApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                        return
                    }
                    self.collapse(force: true)
                }
            }
        }
    }

    /// 二级栏点击转发后的专属收起监控：延迟挂接、监听 mouseUp、忽略目标进程激活与窗口内点击
    private func armPostClickAutoRehideWatchers(clickedPID: pid_t) {
        tearDownAutoRehideWatchers()
        scheduleAutoRehideTimerIfNeeded()

        let settings = settingsStore.settings
        let installTime = Date()

        // 延迟 350ms 后挂接全局点击监听，防止误捕自身刚投递的 CGEvent 点击
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
                    if self.isPointInsideProcessWindow(mouseLoc: mouseLoc, pid: clickedPID) {
                        return
                    }
                    // 延迟 220ms 再折叠，让目标应用的菜单项回调有充裕时间触发
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                        guard let self, self.state != .collapsed else { return }
                        self.collapse(force: true)
                    }
                }
            }
        }

        if settings.rehideOnFocusLoss {
            workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in
                    guard let self, self.state != .collapsed else { return }
                    let activatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    let pid = activatedApp?.processIdentifier
                    if pid == ProcessInfo.processInfo.processIdentifier || pid == clickedPID {
                        return
                    }
                    self.collapse(force: true)
                }
            }
        }
    }

    private func isPointInsideProcessWindow(mouseLoc: NSPoint, pid: pid_t) -> Bool {
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 900
        let cgPoint = CGPoint(x: mouseLoc.x, y: primaryHeight - mouseLoc.y)

        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for entry in list {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }
            if bounds.contains(cgPoint) {
                return true
            }
        }
        return false
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

    // MARK: - Coordinate & Divider Helpers

    private func prepareDividersForRearrangement() {
        hiddenDividerItem.length = Constants.arrangeDividerLength
        alwaysHiddenDividerItem?.length = Constants.arrangeDividerLength
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
            // 仅切换图标或分割线样式时直接重绘模板图，避免无意义的窗口扫描与重排
            refreshArt()
        }
    }

    private func refreshArt() {
        let settings = settingsStore.settings
        let isExpanded = state != .collapsed
        toggleItem.button?.image = StatusItemArt.toggleImage(
            style: settings.toggleIconStyle,
            isExpanded: isExpanded
        )
        hiddenDividerItem.button?.image = StatusItemArt.dividerImage(
            style: settings.dividerStyle,
            isAlwaysHidden: false
        )
        alwaysHiddenDividerItem?.button?.image = StatusItemArt.dividerImage(
            style: settings.dividerStyle,
            isAlwaysHidden: true
        )
    }

    private func statusItemScreenFrame(_ item: NSStatusItem) -> CGRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.frame
    }

    private func currentMenuBarContext() -> (
        cgMinY: CGFloat,
        screenMaxX: CGFloat,
        screenCGFrame: CGRect,
        auxiliaryTopLeft: CGRect?,
        auxiliaryTopRight: CGRect?
    ) {
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 900
        let toggleScreen = statusItemScreenFrame(toggleItem).flatMap { frame in
            NSScreen.screens.first { $0.frame.intersects(frame) }
        } ?? NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main

        guard let screen = toggleScreen else {
            return (0, 1440, CGRect(x: 0, y: 0, width: 1440, height: 900), nil, nil)
        }
        let cgMinY = primaryHeight - screen.frame.maxY
        let screenCGFrame = CGRect(
            x: screen.frame.minX,
            y: cgMinY,
            width: screen.frame.width,
            height: screen.frame.height
        )
        return (cgMinY, screen.frame.maxX, screenCGFrame, screen.auxiliaryTopLeftArea, screen.auxiliaryTopRightArea)
    }

    private func liveDividerSnapshots() -> (toggle: RawStatusWindow, hidden: RawStatusWindow, always: RawStatusWindow?)? {
        let ctx = currentMenuBarContext()
        let raw = MenuBarScanner.readRawStatusWindows()
        let classified = SectionLayoutEngine.classifyOwnStatusWindows(
            raw,
            ownPID: ProcessInfo.processInfo.processIdentifier,
            menuBarCGMinY: ctx.cgMinY
        )
        guard let toggleWin = classified.toggle, let hiddenWin = classified.hiddenDivider else {
            return nil
        }
        let alwaysWin = (alwaysHiddenDividerItem != nil) ? classified.alwaysHiddenDivider : nil
        return (toggleWin, hiddenWin, alwaysWin)
    }

    private func liveDividerCGFrames() -> (toggle: CGRect, hidden: CGRect, always: CGRect?)? {
        if let snaps = liveDividerSnapshots() {
            return (snaps.toggle.cgFrame, snaps.hidden.cgFrame, snaps.always?.cgFrame)
        }

        // 退回到 AppKit frame（单屏或首次初始化窗口尚未进 CGWindowList 时）
        guard let toggleAppKit = statusItemScreenFrame(toggleItem),
              let hiddenAppKit = statusItemScreenFrame(hiddenDividerItem) else {
            return nil
        }
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 900
        func toCG(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
        }
        let alwaysAppKit = alwaysHiddenDividerItem.flatMap { statusItemScreenFrame($0) }
        return (toCG(toggleAppKit), toCG(hiddenAppKit), alwaysAppKit.map(toCG))
    }
}
