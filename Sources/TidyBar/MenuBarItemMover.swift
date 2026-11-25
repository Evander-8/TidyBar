/**
 * [INPUT]: 依赖 AppKit、CoreGraphics 与 TidyBarCore（MenuBarItemInfo、MenuBarSection、MenuBarMoveResult、SectionLayoutEngine、PermissionManager）
 * [OUTPUT]: 提供 MenuBarItemMover（用于「图标管理」页重排与校准分割线的隔离 .privateState 平滑 Command+Drag 执行器）
 * [POS]: TidyBar 的菜单栏可视化重排底层执行器；绝不向全局键盘流注入物理 Command 按键
 * [PROTOCOL]: Update this header on change, then check GEMINI.md
 */

import AppKit
import CoreGraphics
import Foundation
import TidyBarCore

// ============================================================================
// MARK: - 菜单栏图标 Command+Drag 移动引擎
// ============================================================================

@MainActor
enum MenuBarItemMover {
    /// 将指定菜单栏图标平滑拖拽到目标分区（visible / hidden / alwaysHidden）
    static func move(
        item: MenuBarItemInfo,
        to targetSection: MenuBarSection,
        menuBarCGMinY: CGFloat,
        prepareDividers: @escaping () -> Void,
        readDividerSnapshots: @escaping () -> (toggle: RawStatusWindow, hidden: RawStatusWindow, always: RawStatusWindow?)?
    ) async -> MenuBarMoveResult {
        guard PermissionManager.hasAccessibilityPermission else {
            return .missingAccessibilityPermission
        }

        prepareDividers()
        try? await Task.sleep(nanoseconds: 65_000_000)

        for attempt in 0..<2 {
            guard let dividers = readDividerSnapshots() else {
                return .failed("无法读取菜单栏分割线位置")
            }

            let order = SectionLayoutEngine.validateDividerOrder(
                toggleFrame: dividers.toggle.cgFrame,
                hiddenDividerFrame: dividers.hidden.cgFrame,
                alwaysHiddenDividerFrame: dividers.always?.cgFrame
            )
            guard order == .valid else {
                return .dividerOrderInvalid
            }

            guard let currentFrame = currentCGFrame(for: item.windowID, menuBarCGMinY: menuBarCGMinY) else {
                return .failed("目标图标已不在当前屏幕菜单栏中")
            }

            if isInSection(
                midX: currentFrame.midX,
                section: targetSection,
                hiddenRightX: dividers.hidden.cgFrame.maxX,
                alwaysRightX: dividers.always?.cgFrame.maxX
            ) {
                return .moved
            }

            let offset: CGFloat = attempt == 0 ? 0 : 14
            let destination = SectionLayoutEngine.computeMoveDestination(
                targetSection: targetSection,
                toggleCGFrame: dividers.toggle.cgFrame,
                hiddenDividerCGFrame: dividers.hidden.cgFrame,
                alwaysHiddenDividerCGFrame: dividers.always?.cgFrame,
                attemptOffset: offset
            )

            let startPoint = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
            await performSessionCommandDrag(from: startPoint, to: destination, restoreCursor: true)
            try? await Task.sleep(nanoseconds: 75_000_000)

            guard let updatedDividers = readDividerSnapshots(),
                  let afterFrame = currentCGFrame(for: item.windowID, menuBarCGMinY: menuBarCGMinY) else {
                continue
            }

            if isInSection(
                midX: afterFrame.midX,
                section: targetSection,
                hiddenRightX: updatedDividers.hidden.cgFrame.maxX,
                alwaysRightX: updatedDividers.always?.cgFrame.maxX
            ) {
                return .moved
            }

            if attempt == 1 {
                if abs(afterFrame.midX - currentFrame.midX) < 4 {
                    return .immovableSystemItem
                }
                return .failed("未能移动到目标分区，可手动按住 ⌘ 拖入分隔线左侧")
            }
        }

        return .failed("未能完成图标移动")
    }

    /// 将漂移的「|」分割线拖回 TidyBar 主开关紧邻左侧，把夹在中间的图标直接收入隐藏区
    static func alignHiddenDividerNextToToggle(
        menuBarCGMinY: CGFloat,
        prepareDividers: @escaping () -> Void,
        readDividerSnapshots: @escaping () -> (toggle: RawStatusWindow, hidden: RawStatusWindow, always: RawStatusWindow?)?
    ) async -> MenuBarMoveResult {
        guard PermissionManager.hasAccessibilityPermission else {
            return .missingAccessibilityPermission
        }

        prepareDividers()
        try? await Task.sleep(nanoseconds: 65_000_000)

        guard let dividers = readDividerSnapshots() else {
            return .failed("无法读取菜单栏分割线位置")
        }

        let start = CGPoint(x: dividers.hidden.cgFrame.midX, y: dividers.hidden.cgFrame.midY)
        let dest = CGPoint(x: dividers.toggle.cgFrame.minX - 4, y: dividers.toggle.cgFrame.midY)
        if abs(start.x - dest.x) < 12 {
            return .moved
        }

        await performSessionCommandDrag(from: start, to: dest, restoreCursor: true)
        try? await Task.sleep(nanoseconds: 75_000_000)

        guard let updated = readDividerSnapshots() else {
            return .failed("校准后读取位置失败")
        }
        let between = SectionLayoutEngine.itemsBetweenHiddenDividerAndToggle(
            MenuBarScanner.readRawStatusWindows(),
            toggleCGFrame: updated.toggle.cgFrame,
            hiddenDividerCGFrame: updated.hidden.cgFrame,
            menuBarCGMinY: menuBarCGMinY,
            ownPID: ProcessInfo.processInfo.processIdentifier
        )
        return between.isEmpty ? .moved : .failed("仍有图标位于分割线与主开关之间，请再试一次")
    }

    // MARK: - Private Helpers

    private static func isInSection(
        midX: CGFloat,
        section: MenuBarSection,
        hiddenRightX: CGFloat,
        alwaysRightX: CGFloat?
    ) -> Bool {
        switch section {
        case .alwaysHidden:
            guard let alwaysRightX else { return false }
            return midX <= alwaysRightX
        case .hidden:
            if let alwaysRightX, midX <= alwaysRightX {
                return false
            }
            return midX <= hiddenRightX
        case .visible:
            return midX > hiddenRightX
        }
    }

    private static func currentCGFrame(for windowID: CGWindowID, menuBarCGMinY: CGFloat) -> CGRect? {
        MenuBarScanner.readRawStatusWindows()
            .first { $0.windowID == windowID && abs($0.cgFrame.minY - menuBarCGMinY) <= 10 }?
            .cgFrame
    }

    private static func performSessionCommandDrag(
        from start: CGPoint,
        to destination: CGPoint,
        restoreCursor: Bool
    ) async {
        let source = CGEventSource(stateID: .privateState)
        let originalCursor = restoreCursor ? CGEvent(source: nil)?.location : nil

        CGWarpMouseCursorPosition(start)
        postHIDMouseEvent(source: source, type: .mouseMoved, point: start, flags: [])
        try? await Task.sleep(nanoseconds: 12_000_000)

        postHIDMouseEvent(source: source, type: .leftMouseDown, point: start, flags: .maskCommand)
        try? await Task.sleep(nanoseconds: 22_000_000)

        let steps = 8
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let pt = CGPoint(
                x: start.x + (destination.x - start.x) * t,
                y: start.y + (destination.y - start.y) * t
            )
            postHIDMouseEvent(source: source, type: .leftMouseDragged, point: pt, flags: .maskCommand)
            try? await Task.sleep(nanoseconds: 8_000_000)
        }

        try? await Task.sleep(nanoseconds: 24_000_000)
        postHIDMouseEvent(source: source, type: .leftMouseUp, point: destination, flags: .maskCommand)
        try? await Task.sleep(nanoseconds: 16_000_000)

        if let originalCursor {
            CGWarpMouseCursorPosition(originalCursor)
            postHIDMouseEvent(source: source, type: .mouseMoved, point: originalCursor, flags: [])
        }
    }

    private static func postHIDMouseEvent(
        source: CGEventSource?,
        type: CGEventType,
        point: CGPoint,
        flags: CGEventFlags
    ) {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return }
        event.flags = flags
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cghidEventTap)
    }
}
