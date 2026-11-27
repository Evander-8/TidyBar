/**
 * [INPUT]: 依赖 AppKit、SwiftUI、TidyBarCore（SettingsStore、HotkeyManager、LaunchAtLoginService、PermissionManager、SectionLayoutEngine、MenuBarMoveResult）与 MenuBarScanner.FullMenuBarSnapshot
 * [OUTPUT]: 提供 SettingsWindowController（按需懒加载 SwiftUI 偏好设置窗，首屏支持可视化勾选/移动隐藏图标）
 * [POS]: TidyBar 的设置与图标管理窗口，关闭即释放 SwiftUI 视图树，保证常驻零额外内存
 * [PROTOCOL]: Update this header on change, then check GEMINI.md
 */

import AppKit
import Carbon
import SwiftUI
import TidyBarCore

// ============================================================================
// MARK: - 图标管理动作协议（由 AppDelegate 注入，避免与 MenuBarController 循环引用）
// ============================================================================

@MainActor
struct MenuBarActions {
    let scanAll: () async -> FullMenuBarSnapshot
    let moveItem: (MenuBarItemInfo, MenuBarSection) async -> MenuBarMoveResult
    let alignDivider: () async -> MenuBarMoveResult
    let saveCurrentLayout: () async -> Int
}

// ============================================================================
// MARK: - 懒加载设置窗控制器
// ============================================================================

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settingsStore: SettingsStore
    private let hotkeyManager: HotkeyManager

    var menuBarActions: MenuBarActions?

    private var window: NSWindow?
    private var hostingController: NSHostingController<SettingsRootView>?

    init(settingsStore: SettingsStore, hotkeyManager: HotkeyManager) {
        self.settingsStore = settingsStore
        self.hotkeyManager = hotkeyManager
        super.init()
    }

    func show(tab: Int = 0) {
        guard let actions = menuBarActions else { return }

        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .tidyBarSelectSettingsTab, object: tab)
            return
        }

        let rootView = SettingsRootView(
            settingsStore: settingsStore,
            hotkeyManager: hotkeyManager,
            menuBarActions: actions,
            initialTab: tab
        )
        let host = NSHostingController(rootView: rootView)
        let createdWindow = NSWindow(contentViewController: host)
        createdWindow.title = "TidyBar 偏好设置"
        createdWindow.styleMask = [.titled, .closable, .miniaturizable]
        createdWindow.setContentSize(NSSize(width: 660, height: 520))
        createdWindow.center()
        createdWindow.isReleasedWhenClosed = false
        createdWindow.delegate = self

        hostingController = host
        window = createdWindow

        createdWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        hotkeyManager.setSuspended(false)
        window?.contentViewController = nil
        hostingController = nil
        window = nil
    }
}

private extension Notification.Name {
    static let tidyBarSelectSettingsTab = Notification.Name("com.tidybar.selectSettingsTab")
}

// ============================================================================
// MARK: - SwiftUI 偏好设置状态桥接与根视图
// ============================================================================

@MainActor
private final class SettingsViewModel: ObservableObject {
    @Published var settings: TidyBarSettings
    @Published var launchAtLogin: Bool
    @Published var launchRequiresApproval: Bool
    @Published var hasAccessibility: Bool
    @Published var hotkeyConflictMessage: String?
    @Published var launchErrorMessage: String?

    @Published var snapshot: FullMenuBarSnapshot?
    @Published var isBusyMoving = false
    @Published var iconStatusMessage: String?
    @Published var iconStatusIsError = false

    private let store: SettingsStore
    private let hotkeyManager: HotkeyManager
    private let menuBarActions: MenuBarActions
    private var listenerID: UUID?

    init(store: SettingsStore, hotkeyManager: HotkeyManager, menuBarActions: MenuBarActions) {
        self.store = store
        self.hotkeyManager = hotkeyManager
        self.menuBarActions = menuBarActions
        self.settings = store.settings
        self.launchAtLogin = LaunchAtLoginService.isEnabled
        self.launchRequiresApproval = LaunchAtLoginService.requiresApproval
        self.hasAccessibility = PermissionManager.hasAccessibilityPermission

        self.listenerID = store.addChangeListener { [weak self] updated in
            DispatchQueue.main.async {
                guard let self, self.settings != updated else { return }
                self.settings = updated
            }
        }
    }

    deinit {
        if let id = listenerID {
            store.removeChangeListener(id)
        }
    }

    func update(_ transform: (inout TidyBarSettings) -> Void) {
        let old = settings
        store.update(transform)
        let next = store.settings
        guard next != old else { return }
        settings = next
        if next.hotkeyEnabled != old.hotkeyEnabled || next.toggleHotkey != old.toggleHotkey {
            syncHotkeyRegistration()
        }
    }

    func refreshIcons() async {
        hasAccessibility = PermissionManager.hasAccessibilityPermission
        snapshot = await menuBarActions.scanAll()
    }

    func moveIcon(_ item: MenuBarItemInfo, to section: MenuBarSection) async {
        guard !isBusyMoving else { return }
        isBusyMoving = true
        iconStatusMessage = "正在移动「\(item.displayLabel)」到\(section.displayTitle)…"
        iconStatusIsError = false

        let result = await menuBarActions.moveItem(item, section)
        applyMoveResult(result, successMessage: "已将「\(item.displayLabel)」移至\(section.displayTitle)")
        await refreshIcons()
        isBusyMoving = false
    }

    func alignDivider() async {
        guard !isBusyMoving else { return }
        isBusyMoving = true
        iconStatusMessage = "正在校准分割线位置…"
        iconStatusIsError = false

        let result = await menuBarActions.alignDivider()
        applyMoveResult(result, successMessage: "已将分割线校准到主开关旁，中间图标已收纳隐藏")
        await refreshIcons()
        isBusyMoving = false
    }

    func saveCurrentLayout() async {
        guard !isBusyMoving else { return }
        isBusyMoving = true
        let count = await menuBarActions.saveCurrentLayout()
        iconStatusIsError = count == 0
        iconStatusMessage = count > 0
            ? "已记住当前 \(count) 个图标的分区规则，重启后将自动恢复"
            : "暂未扫描到可记住的菜单栏图标"
        isBusyMoving = false
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchErrorMessage = nil
        do {
            try LaunchAtLoginService.setEnabled(enabled)
            launchAtLogin = LaunchAtLoginService.isEnabled || enabled
            launchRequiresApproval = LaunchAtLoginService.requiresApproval
        } catch {
            launchErrorMessage = "登录项设置失败（未签名开发构建可在打包 .app 后启用）：\(error.localizedDescription)"
            launchAtLogin = LaunchAtLoginService.isEnabled
        }
    }

    func refreshPermissions() {
        hasAccessibility = PermissionManager.hasAccessibilityPermission
        launchAtLogin = LaunchAtLoginService.isEnabled
        launchRequiresApproval = LaunchAtLoginService.requiresApproval
    }

    func syncHotkeyRegistration() {
        hotkeyConflictMessage = nil
        if settings.hotkeyEnabled {
            let ok = hotkeyManager.register(combo: settings.toggleHotkey)
            if !ok {
                hotkeyConflictMessage = "快捷键 \(settings.toggleHotkey.displayString) 可能已被其他应用占用，请换一组。"
            }
        } else {
            hotkeyManager.unregister()
        }
    }

    private func applyMoveResult(_ result: MenuBarMoveResult, successMessage: String) {
        switch result {
        case .moved:
            iconStatusMessage = successMessage
            iconStatusIsError = false
        case .missingAccessibilityPermission:
            iconStatusMessage = "需要「辅助功能」权限才能自动移动菜单栏图标，请先授权后再试。"
            iconStatusIsError = true
        case .immovableSystemItem:
            iconStatusMessage = "该系统状态图标被 macOS 固定在最右侧，无法隐藏。"
            iconStatusIsError = true
        case .dividerOrderInvalid:
            iconStatusMessage = "分割线顺序异常：请先按住 ⌘ 将「|」拖到 TidyBar 主图标左侧。"
            iconStatusIsError = true
        case .failed(let message):
            iconStatusMessage = message
            iconStatusIsError = true
        }
    }
}

private struct SettingsRootView: View {
    @StateObject private var vm: SettingsViewModel
    @State private var selectedTab: Int

    private let hotkeyManager: HotkeyManager

    init(
        settingsStore: SettingsStore,
        hotkeyManager: HotkeyManager,
        menuBarActions: MenuBarActions,
        initialTab: Int
    ) {
        _vm = StateObject(
            wrappedValue: SettingsViewModel(
                store: settingsStore,
                hotkeyManager: hotkeyManager,
                menuBarActions: menuBarActions
            )
        )
        _selectedTab = State(initialValue: max(0, min(4, initialTab)))
        self.hotkeyManager = hotkeyManager
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("图标管理").tag(0)
                Text("通用").tag(1)
                Text("外观").tag(2)
                Text("快捷键").tag(3)
                Text("权限与引导").tag(4)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            ScrollView {
                Group {
                    switch selectedTab {
                    case 0:
                        IconManagerTab(vm: vm, onOpenPermissions: { selectedTab = 4 })
                    case 1:
                        GeneralSettingsTab(vm: vm)
                    case 2:
                        AppearanceSettingsTab(vm: vm)
                    case 3:
                        HotkeySettingsTab(vm: vm, hotkeyManager: hotkeyManager)
                    default:
                        PermissionsGuideTab(vm: vm)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 660, height: 520)
        .onReceive(NotificationCenter.default.publisher(for: .tidyBarSelectSettingsTab)) { note in
            if let tab = note.object as? Int {
                selectedTab = max(0, min(4, tab))
            }
        }
    }
}

// ============================================================================
// MARK: - 分页 0：可视化图标管理
// ============================================================================

private struct IconManagerTab: View {
    @ObservedObject var vm: SettingsViewModel
    let onOpenPermissions: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerToolbar

            if !vm.hasAccessibility {
                accessibilityBanner
            }

            if let drifted = vm.snapshot?.driftedBetweenCount, drifted > 0 {
                driftedBanner(count: drifted)
            }

            if let message = vm.iconStatusMessage {
                HStack(spacing: 8) {
                    Image(systemName: vm.iconStatusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(vm.iconStatusIsError ? .orange : .green)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(vm.iconStatusIsError ? .primary : .secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if let snap = vm.snapshot {
                sectionBox(
                    title: "已隐藏图标（点击主开关或按 \(vm.settings.toggleHotkey.displayString) 查看）",
                    items: snap.hiddenItems,
                    emptyText: "当前暂无隐藏图标，可从下方「常显图标」列表中一键隐藏",
                    section: .hidden,
                    screenMaxX: snap.screenMaxX
                )

                sectionBox(
                    title: "常显图标（始终显示在顶部菜单栏）",
                    items: snap.visibleItems,
                    emptyText: "未检测到其他常显状态栏图标",
                    section: .visible,
                    screenMaxX: snap.screenMaxX
                )

                if vm.settings.enableAlwaysHiddenSection {
                    sectionBox(
                        title: "总是隐藏区（仅按住 Option 点击主开关时展开）",
                        items: snap.alwaysHiddenItems,
                        emptyText: "可将极少查看的图标移入此区保持彻底安静",
                        section: .alwaysHidden,
                        screenMaxX: snap.screenMaxX
                    )
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在扫描当前菜单栏图标…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .task {
            await vm.refreshIcons()
        }
    }

    private var headerToolbar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if let snap = vm.snapshot {
                    Text("常显 \(snap.visibleItems.count) · 隐藏 \(snap.hiddenItems.count) · 总是隐藏 \(snap.alwaysHiddenItems.count)")
                        .font(.subheadline.weight(.medium))
                } else {
                    Text("菜单栏图标分区管理")
                        .font(.subheadline.weight(.medium))
                }
                Text("点击按钮即可自动将图标移入对应分组；重启后将按规则自动恢复。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !vm.settings.pinnedSections.isEmpty {
                    Text("已记住 \(vm.settings.pinnedSections.count) 条分区规则，应用或系统重启后自动归位。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if vm.isBusyMoving {
                ProgressView().controlSize(.small)
            }
            Button("记住当前布局") {
                Task { await vm.saveCurrentLayout() }
            }
            .disabled(vm.isBusyMoving)
            Button {
                Task { await vm.refreshIcons() }
            } label: {
                Label("刷新列表", systemImage: "arrow.clockwise")
            }
            .disabled(vm.isBusyMoving)
        }
    }

    private var accessibilityBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("需要「辅助功能」权限以一键隐藏/还原图标")
                    .font(.caption.weight(.medium))
                Text("授权后 TidyBar 可自动帮你调整菜单栏图标顺序；也可手工按住 ⌘ 拖到「|」左侧。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("去授权") {
                _ = PermissionManager.requestAccessibilityPermission(prompt: true)
                PermissionManager.openAccessibilitySettings()
                onOpenPermissions()
            }
            .controlSize(.small)
            Button("刷新") {
                Task { await vm.refreshIcons() }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func driftedBanner(count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(.blue)
            Text("检测到有 \(count) 个图标位于「|」分割线与 TidyBar 主开关之间，尚未被收纳。")
                .font(.caption)
            Spacer()
            Button("一键校准并隐藏") {
                Task { await vm.alignDivider() }
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(vm.isBusyMoving)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func sectionBox(
        title: String,
        items: [CapturedMenuBarItem],
        emptyText: String,
        section: MenuBarSection,
        screenMaxX: CGFloat
    ) -> some View {
        GroupBox(title) {
            if items.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            } else {
                VStack(spacing: 6) {
                    ForEach(items, id: \.info.windowID) { captured in
                        iconRow(captured: captured, section: section, screenMaxX: screenMaxX)
                        if captured.info.windowID != items.last?.info.windowID {
                            Divider()
                        }
                    }
                }
                .padding(6)
            }
        }
    }

    private func iconRow(
        captured: CapturedMenuBarItem,
        section: MenuBarSection,
        screenMaxX: CGFloat
    ) -> some View {
        let info = captured.info
        let isPinned = SectionLayoutEngine.isLikelySystemPinnedItem(
            ownerName: info.ownerName,
            title: info.title,
            cgFrame: info.cgFrame,
            screenMaxX: screenMaxX
        )

        return HStack(spacing: 10) {
            Image(nsImage: captured.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 18)
                .padding(3)
                .background(Color.secondary.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 1) {
                Text(info.displayLabel)
                    .font(.system(size: 13))
                    .lineLimit(1)
                if isPinned {
                    Text("系统固定在最右侧")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isPinned {
                Text("不可隐藏")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                rowButtons(for: info, currentSection: section)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func rowButtons(for info: MenuBarItemInfo, currentSection: MenuBarSection) -> some View {
        HStack(spacing: 6) {
            switch currentSection {
            case .visible:
                Button("隐藏") {
                    Task { await vm.moveIcon(info, to: .hidden) }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(vm.isBusyMoving)

                if vm.settings.enableAlwaysHiddenSection {
                    Button("总是隐藏") {
                        Task { await vm.moveIcon(info, to: .alwaysHidden) }
                    }
                    .controlSize(.small)
                    .disabled(vm.isBusyMoving)
                }

            case .hidden:
                Button("移回常显") {
                    Task { await vm.moveIcon(info, to: .visible) }
                }
                .controlSize(.small)
                .disabled(vm.isBusyMoving)

                if vm.settings.enableAlwaysHiddenSection {
                    Button("总是隐藏") {
                        Task { await vm.moveIcon(info, to: .alwaysHidden) }
                    }
                    .controlSize(.small)
                    .disabled(vm.isBusyMoving)
                }

            case .alwaysHidden:
                Button("移至隐藏") {
                    Task { await vm.moveIcon(info, to: .hidden) }
                }
                .controlSize(.small)
                .disabled(vm.isBusyMoving)

                Button("移回常显") {
                    Task { await vm.moveIcon(info, to: .visible) }
                }
                .controlSize(.small)
                .disabled(vm.isBusyMoving)
            }
        }
    }
}

// ============================================================================
// MARK: - 分页 1：通用设置
// ============================================================================

private struct GeneralSettingsTab: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("展开行为") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("显示模式", selection: Binding(
                        get: { vm.settings.displayMode },
                        set: { mode in vm.update { $0.displayMode = mode } }
                    )) {
                        ForEach(DisplayMode.allCases, id: \.self) { mode in
                            Text(mode.displayTitle).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    Text(vm.settings.displayMode.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    Picker("展开后自动收起", selection: Binding(
                        get: { vm.settings.autoRehideDelay },
                        set: { delay in vm.update { $0.autoRehideDelay = delay } }
                    )) {
                        ForEach(AutoRehideDelay.allCases, id: \.self) { delay in
                            Text(delay.displayTitle).tag(delay)
                        }
                    }

                    Toggle("点击其他位置或切换应用时自动收起", isOn: Binding(
                        get: { vm.settings.rehideOnFocusLoss },
                        set: { flag in vm.update { $0.rehideOnFocusLoss = flag } }
                    ))

                    Toggle("启用「总是隐藏区」(‖) 三段式分区", isOn: Binding(
                        get: { vm.settings.enableAlwaysHiddenSection },
                        set: { flag in vm.update { $0.enableAlwaysHiddenSection = flag } }
                    ))
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("系统启动") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("登录 macOS 时自动启动 TidyBar", isOn: Binding(
                        get: { vm.launchAtLogin },
                        set: { vm.setLaunchAtLogin($0) }
                    ))

                    if vm.launchRequiresApproval {
                        Text("请在「系统设置 → 通用 → 登录项」中允许 TidyBar 后台运行。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if let error = vm.launchErrorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// ============================================================================
// MARK: - 分页 2：外观设置
// ============================================================================

private struct StyleOptionCard<Content: View>: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let iconContent: () -> Content

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                iconContent()
                    .frame(height: 22)
                Text(title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? Color.accentColor : Color.secondary.opacity(isHovered ? 0.45 : 0.25),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.16)
        }
        return Color.primary.opacity(isHovered ? 0.06 : 0.025)
    }
}

private struct AppearanceSettingsTab: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("主按钮图标样式") {
                HStack(spacing: 12) {
                    ForEach(ToggleIconStyle.allCases, id: \.self) { style in
                        StyleOptionCard(
                            title: style.displayTitle,
                            isSelected: vm.settings.toggleIconStyle == style
                        ) {
                            vm.update { $0.toggleIconStyle = style }
                        } iconContent: {
                            Image(nsImage: StatusItemArt.toggleImage(style: style, isExpanded: false))
                                .frame(width: 24, height: 22)
                        }
                    }
                }
                .padding(8)
            }

            GroupBox("分割线样式") {
                HStack(spacing: 12) {
                    ForEach(DividerStyle.allCases, id: \.self) { style in
                        StyleOptionCard(
                            title: style.displayTitle,
                            isSelected: vm.settings.dividerStyle == style
                        ) {
                            vm.update { $0.dividerStyle = style }
                        } iconContent: {
                            HStack(spacing: 6) {
                                Image(nsImage: StatusItemArt.dividerImage(style: style, isAlwaysHidden: true))
                                Image(nsImage: StatusItemArt.dividerImage(style: style, isAlwaysHidden: false))
                            }
                        }
                    }
                }
                .padding(8)
            }

            GroupBox("二级下拉栏布局") {
                Stepper(
                    "每行最多显示图标数：\(vm.settings.secondaryBarMaxColumns) 个",
                    value: Binding(
                        get: { vm.settings.secondaryBarMaxColumns },
                        set: { val in vm.update { $0.secondaryBarMaxColumns = val } }
                    ),
                    in: 4...20
                )
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// ============================================================================
// MARK: - 分页 3：快捷键录制
// ============================================================================

private struct HotkeySettingsTab: View {
    @ObservedObject var vm: SettingsViewModel
    let hotkeyManager: HotkeyManager

    @State private var isRecording = false
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("全局展开 / 收起快捷键") {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("启用全局快捷键", isOn: Binding(
                        get: { vm.settings.hotkeyEnabled },
                        set: { flag in vm.update { $0.hotkeyEnabled = flag } }
                    ))

                    HStack {
                        Text("切换菜单栏图标：")
                        Spacer()
                        Button(isRecording ? "请按下新组合键… (Esc 取消)" : vm.settings.toggleHotkey.displayString) {
                            toggleRecording()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(isRecording ? .orange : .accentColor)
                        .disabled(!vm.settings.hotkeyEnabled)

                        Button("恢复默认") {
                            stopRecording()
                            vm.update { $0.toggleHotkey = .defaultToggle }
                        }
                        .disabled(!vm.settings.hotkeyEnabled)
                    }

                    if let conflict = vm.hotkeyConflictMessage {
                        Text(conflict)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("支持搭配 ⌘ / ⌥ / ⌃ / ⇧ 修饰键。按住 ⌥ 再触发可在二级栏或原地一并展开「总是隐藏区」。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
            return
        }
        isRecording = true
        hotkeyManager.setSuspended(true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                stopRecording()
                return nil
            }
            let modifiers = HotkeyCombo.carbonModifiers(from: event.modifierFlags)
            guard modifiers != 0 else {
                NSSound.beep()
                return nil
            }
            let keyCode = UInt32(event.keyCode)
            let display = HotkeyCombo.formatDisplayString(keyCode: keyCode, modifiers: modifiers)
            let combo = HotkeyCombo(keyCode: keyCode, modifiers: modifiers, displayString: display)
            stopRecording()
            vm.update { $0.toggleHotkey = combo }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        isRecording = false
        hotkeyManager.setSuspended(false)
    }
}

// ============================================================================
// MARK: - 分页 4：权限与三段式引导
// ============================================================================

private struct PermissionsGuideTab: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("三段式菜单栏分组方式") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("[总是隐藏区]   ‖   [隐藏区]   |   [TidyBar 开关]   [常显区]")
                        .font(.system(.callout, design: .monospaced))
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    Text("• 推荐直接在「图标管理」分页点击「隐藏 / 移回常显」，无需手工拖拽。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("• 也可按住 ⌘ 手动拖动任意菜单栏图标到「|」左侧隐藏，或拖到「‖」左侧放入总是隐藏区。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("系统权限（无需屏幕录制权限）") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: vm.hasAccessibility ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(vm.hasAccessibility ? .green : .orange)
                        VStack(alignment: .leading) {
                            Text("辅助功能权限").fontWeight(.medium)
                            Text("用于在「图标管理」一键移动图标，以及点击二级下拉栏图标时转发点击；全程不请求屏幕录制权限").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(vm.hasAccessibility ? "已授权" : "授权 / 设置") {
                            _ = PermissionManager.requestAccessibilityPermission(prompt: true)
                            PermissionManager.openAccessibilitySettings()
                        }
                    }

                    HStack {
                        Spacer()
                        Button("刷新权限状态") {
                            vm.refreshPermissions()
                        }
                        .controlSize(.small)
                    }
                }
                .padding(8)
            }
        }
        .onAppear {
            vm.refreshPermissions()
        }
    }
}
