/**
 * [INPUT]: 依赖 AppKit、TidyBarCore（SectionLayoutEngine、PermissionManager、MenuBarItemInfo）与 MenuBarScanner.MenuBarScanResult
 * [OUTPUT]: 提供 SecondaryBarPanelController（无边框毛玻璃二级下拉栏，支持悬停保活、分区渲染与关闭即释放）
 * [POS]: TidyBar 的二级下拉栏界面层，仅在展开时按需构建视图与监控，隐藏时立即清理图片引用
 * [PROTOCOL]: Update this header on change, then check GEMINI.md
 */

import AppKit
import TidyBarCore

// ============================================================================
// MARK: - 单个菜单栏图标按钮
// ============================================================================

private final class MenuBarIconButton: NSView {
    private let item: CapturedMenuBarItem
    private let onClick: (MenuBarItemInfo, Bool) -> Void
    private let highlightLayer = CALayer()
    private let imageView = NSImageView()
    private var trackingArea: NSTrackingArea?

    init(
        item: CapturedMenuBarItem,
        size: NSSize,
        onClick: @escaping (MenuBarItemInfo, Bool) -> Void
    ) {
        self.item = item
        self.onClick = onClick
        super.init(frame: NSRect(origin: .zero, size: size))

        wantsLayer = true
        layer?.cornerRadius = 7
        toolTip = item.info.displayLabel

        highlightLayer.cornerRadius = 7
        highlightLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.11).cgColor
        highlightLayer.opacity = 0
        layer?.addSublayer(highlightLayer)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        imageView.image = item.image
        addSubview(imageView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(lessThanOrEqualToConstant: size.width - 6),
            imageView.heightAnchor.constraint(lessThanOrEqualToConstant: size.height - 6)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        highlightLayer.frame = bounds
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        highlightLayer.opacity = 1
    }

    override func mouseExited(with event: NSEvent) {
        highlightLayer.opacity = 0
    }

    override func mouseDown(with event: NSEvent) {
        highlightLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.18).cgColor
        highlightLayer.opacity = 1
    }

    override func mouseUp(with event: NSEvent) {
        highlightLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.11).cgColor
        let local = convert(event.locationInWindow, from: nil)
        guard bounds.contains(local) else {
            highlightLayer.opacity = 0
            return
        }
        onClick(item.info, false)
    }

    override func rightMouseDown(with event: NSEvent) {
        highlightLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.18).cgColor
        highlightLayer.opacity = 1
    }

    override func rightMouseUp(with event: NSEvent) {
        highlightLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.11).cgColor
        let local = convert(event.locationInWindow, from: nil)
        guard bounds.contains(local) else {
            highlightLayer.opacity = 0
            return
        }
        onClick(item.info, true)
    }
}

private final class NonActivatingSecondaryPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// ============================================================================
// MARK: - 二级下拉栏根容器（追踪鼠标整体悬停）
// ============================================================================

private final class PanelHoverContainerView: NSVisualEffectView {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }
}

// ============================================================================
// MARK: - 二级下拉栏面板控制器
// ============================================================================

final class SecondaryBarPanelController {
    var onSelectItem: ((MenuBarItemInfo, Bool) -> Void)?
    var onSwitchToInline: (() -> Void)?
    var onRequestPermissions: (() -> Void)?
    var onManageIcons: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onDismissRequested: (() -> Void)?

    private var panel: NSPanel?
    private var escMonitor: Any?

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    var panelFrame: CGRect? {
        panel?.frame
    }

    @MainActor
    func show(
        result: MenuBarScanResult,
        anchorRect: CGRect,
        maxColumns: Int,
        includeAlwaysHidden: Bool
    ) {
        hide()

        let hasAccessibility = PermissionManager.hasAccessibilityPermission
        let needsBanner = !hasAccessibility

        let combinedCount = result.hiddenItems.count + (includeAlwaysHidden ? result.alwaysHiddenItems.count : 0)
        let hasSeparator = includeAlwaysHidden && !result.hiddenItems.isEmpty && !result.alwaysHiddenItems.isEmpty

        let targetScreen = NSScreen.screens.first(where: { $0.frame.intersects(anchorRect) })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let screen = targetScreen else { return }

        let itemSize = CGSize(width: 30, height: 28)
        let itemSpacing: CGFloat = 6
        let padding: CGFloat = 10

        let frame = SectionLayoutEngine.computeSecondaryBarFrame(
            anchorRect: anchorRect,
            itemCount: combinedCount,
            hasSectionSeparator: hasSeparator,
            showsPermissionBanner: needsBanner,
            itemSize: itemSize,
            itemSpacing: itemSpacing,
            padding: padding,
            maxColumns: maxColumns,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )

        let createdPanel = NonActivatingSecondaryPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        createdPanel.level = .statusBar
        createdPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        createdPanel.isOpaque = false
        createdPanel.backgroundColor = .clear
        createdPanel.hasShadow = true
        createdPanel.hidesOnDeactivate = false

        let effectView = PanelHoverContainerView(frame: NSRect(origin: .zero, size: frame.size))
        effectView.material = .popover
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.maskImage = Self.roundedMaskImage(size: frame.size, cornerRadius: 12)
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 0.75
        effectView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        effectView.onHoverChanged = { [weak self] hovering in
            self?.onHoverChanged?(hovering)
        }

        let rootStack = NSStackView()
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 8

        effectView.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: effectView.topAnchor, constant: padding),
            rootStack.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: padding),
            rootStack.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -padding),
            rootStack.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -padding)
        ])

        if combinedCount == 0 {
            let emptyStack = NSStackView()
            emptyStack.orientation = .horizontal
            emptyStack.alignment = .centerY
            emptyStack.spacing = 8

            let hint = NSTextField(labelWithString: "暂无已隐藏图标")
            hint.font = .systemFont(ofSize: 12)
            hint.textColor = .secondaryLabelColor
            emptyStack.addArrangedSubview(hint)

            let manageBtn = NSButton(title: "选择要隐藏的图标…", target: self, action: #selector(handleManageIcons))
            manageBtn.controlSize = .small
            manageBtn.bezelStyle = .rounded
            emptyStack.addArrangedSubview(manageBtn)

            rootStack.addArrangedSubview(emptyStack)
        } else {
            let grid = buildGridRows(
                hiddenItems: result.hiddenItems,
                alwaysHiddenItems: includeAlwaysHidden ? result.alwaysHiddenItems : [],
                itemSize: itemSize,
                itemSpacing: itemSpacing,
                maxColumns: maxColumns
            )
            rootStack.addArrangedSubview(grid)
        }

        if needsBanner {
            let banner = buildPermissionBanner()
            rootStack.addArrangedSubview(banner)
        }

        createdPanel.contentView = effectView
        createdPanel.invalidateShadow()
        createdPanel.orderFrontRegardless()
        panel = createdPanel

        installEscapeMonitor()
    }

    @MainActor
    func hide() {
        removeEscapeMonitor()
        if let current = panel {
            current.contentView?.subviews.forEach { $0.removeFromSuperview() }
            current.contentView = nil
            current.orderOut(nil)
        }
        panel = nil
    }

    // MARK: - Layout Builders

    private func buildGridRows(
        hiddenItems: [CapturedMenuBarItem],
        alwaysHiddenItems: [CapturedMenuBarItem],
        itemSize: NSSize,
        itemSpacing: CGFloat,
        maxColumns: Int
    ) -> NSStackView {
        let vertical = NSStackView()
        vertical.orientation = .vertical
        vertical.alignment = .leading
        vertical.spacing = itemSpacing

        // 构造扁平槽位序列（总是隐藏区在左，隐藏区在右，与顶部菜单栏阅读方向保持一致）
        enum Slot {
            case icon(CapturedMenuBarItem)
            case separator
        }

        var slots: [Slot] = alwaysHiddenItems.map { .icon($0) }
        if !alwaysHiddenItems.isEmpty && !hiddenItems.isEmpty {
            slots.append(.separator)
        }
        slots.append(contentsOf: hiddenItems.map { .icon($0) })

        var currentRow = makeRowStack(spacing: itemSpacing)
        var iconsInRow = 0

        for slot in slots {
            switch slot {
            case .separator:
                if iconsInRow > 0 && iconsInRow < maxColumns {
                    let divider = NSBox()
                    divider.boxType = .separator
                    divider.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([
                        divider.widthAnchor.constraint(equalToConstant: 1),
                        divider.heightAnchor.constraint(equalToConstant: 18)
                    ])
                    currentRow.addArrangedSubview(divider)
                }

            case .icon(let captured):
                if iconsInRow >= maxColumns {
                    vertical.addArrangedSubview(currentRow)
                    currentRow = makeRowStack(spacing: itemSpacing)
                    iconsInRow = 0
                }
                let button = MenuBarIconButton(item: captured, size: itemSize) { [weak self] info, isRightClick in
                    self?.onSelectItem?(info, isRightClick)
                }
                currentRow.addArrangedSubview(button)
                iconsInRow += 1
            }
        }

        if !currentRow.arrangedSubviews.isEmpty {
            vertical.addArrangedSubview(currentRow)
        }
        return vertical
    }

    private func makeRowStack(spacing: CGFloat) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = spacing
        return row
    }

    private func buildPermissionBanner() -> NSView {
        let container = NSStackView()
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 6

        let label = NSTextField(labelWithString: "点击图标需辅助功能权限")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        container.addArrangedSubview(label)

        let grantButton = NSButton(title: "去授权", target: self, action: #selector(handleGrantPermissions))
        grantButton.controlSize = .small
        grantButton.bezelStyle = .rounded
        container.addArrangedSubview(grantButton)

        let inlineButton = NSButton(title: "原地展开", target: self, action: #selector(handleSwitchInline))
        inlineButton.controlSize = .small
        inlineButton.bezelStyle = .rounded
        container.addArrangedSubview(inlineButton)

        return container
    }

    @objc private func handleGrantPermissions() {
        onRequestPermissions?()
    }

    @objc private func handleSwitchInline() {
        onSwitchToInline?()
    }

    @objc private func handleManageIcons() {
        onManageIcons?()
    }

    // MARK: - Escape Key Monitor

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.onDismissRequested?()
                return nil
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
    }

    private static func roundedMaskImage(size: NSSize, cornerRadius: CGFloat) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: cornerRadius,
            left: cornerRadius,
            bottom: cornerRadius,
            right: cornerRadius
        )
        image.resizingMode = .stretch
        return image
    }
}
