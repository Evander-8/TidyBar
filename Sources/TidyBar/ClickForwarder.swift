/**
 * [INPUT]: 依赖 AppKit、CoreGraphics 与 TidyBarCore（MenuBarItemInfo、MenuBarSection、PermissionManager、SectionLayoutEngine）
 * [OUTPUT]: 提供 ClickForwarder（收缩分割线显露目标、等待连续 2 帧静止且避开刘海、锁点净化点击投递）
 * [POS]: TidyBar 的极速状态栏点击转发引擎，单次稳定唤出目标应用原生菜单或浮窗
 * [PROTOCOL]: Update this header on change, then check GEMINI.md
 */

import AppKit
import CoreGraphics
import Foundation
import TidyBarCore

// ============================================================================
// MARK: - 点击转发结果
// ============================================================================

enum ClickForwardOutcome {
    case forwarded
    case missingAccessibilityPermission
    case targetNotReachable
}

// ============================================================================
// MARK: - 极速直击转发器
// ============================================================================

enum ClickForwarder {
    /// 临时收缩分割线显露目标图标，待坐标停稳且不在刘海内后投递纯净鼠标点击
    @MainActor
    static func forwardClick(
        to item: MenuBarItemInfo,
        isRightClick: Bool,
        menuBarCGMinY: CGFloat,
        screenCGFrame: CGRect,
        auxiliaryTopLeft: CGRect?,
        auxiliaryTopRight: CGRect?,
        temporarilyReveal: @escaping (MenuBarSection) -> Void
    ) async -> ClickForwardOutcome {
        guard PermissionManager.hasAccessibilityPermission else {
            return .missingAccessibilityPermission
        }

        temporarilyReveal(item.section)

        guard let settledBounds = await waitForSettledVisibleBounds(
            windowID: item.windowID,
            menuBarCGMinY: menuBarCGMinY,
            screenCGFrame: screenCGFrame,
            auxiliaryTopLeft: auxiliaryTopLeft,
            auxiliaryTopRight: auxiliaryTopRight
        ) else {
            return .targetNotReachable
        }

        // 留出 25ms 待 WindowServer 提交最新热区，再锁点投递零修饰键点击
        try? await Task.sleep(nanoseconds: 25_000_000)
        let clickPoint = CGPoint(x: settledBounds.midX, y: settledBounds.midY)
        await postCleanClickEvent(at: clickPoint, windowID: item.windowID, isRightClick: isRightClick)
        return .forwarded
    }

    // MARK: - Private Helpers

    /// 要求目标图标在当前屏幕菜单栏中已显示、避开刘海，且连续两次采样 X 坐标变化 <= 1pt
    @MainActor
    private static func waitForSettledVisibleBounds(
        windowID: CGWindowID,
        menuBarCGMinY: CGFloat,
        screenCGFrame: CGRect,
        auxiliaryTopLeft: CGRect?,
        auxiliaryTopRight: CGRect?
    ) async -> CGRect? {
        let visibleMinX = screenCGFrame.minX + 2
        let visibleMaxX = screenCGFrame.maxX - 2

        try? await Task.sleep(nanoseconds: 35_000_000)

        var previousX: CGFloat?
        for _ in 0..<18 {
            if let hit = currentStatusEntry(for: windowID, menuBarCGMinY: menuBarCGMinY),
               hit.isOnScreen,
               hit.frame.minX >= visibleMinX,
               hit.frame.maxX <= visibleMaxX {
                let midPoint = CGPoint(x: hit.frame.midX, y: hit.frame.midY)
                let obscured = SectionLayoutEngine.isPointObscuredByNotch(
                    cgPoint: midPoint,
                    screenCGFrame: screenCGFrame,
                    auxiliaryTopLeft: auxiliaryTopLeft,
                    auxiliaryTopRight: auxiliaryTopRight
                )
                if !obscured {
                    if let prev = previousX, abs(prev - hit.frame.minX) <= 1.0 {
                        return hit.frame
                    }
                    previousX = hit.frame.minX
                } else {
                    previousX = nil
                }
            } else {
                previousX = nil
            }
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        return nil
    }

    private static func currentStatusEntry(
        for windowID: CGWindowID,
        menuBarCGMinY: CGFloat
    ) -> (frame: CGRect, isOnScreen: Bool)? {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for entry in list {
            guard let id = entry[kCGWindowNumber as String] as? UInt32,
                  CGWindowID(id) == windowID,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  abs(bounds.minY - menuBarCGMinY) <= 10 else {
                continue
            }
            let isOnScreen = (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false
            return (bounds, isOnScreen)
        }
        return nil
    }

    /// 锁定光标至目标图标中心并使用隔离 .privateState 投递 flags=[] 的纯净左/右键点击
    private static func postCleanClickEvent(
        at point: CGPoint,
        windowID: CGWindowID,
        isRightClick: Bool
    ) async {
        let source = CGEventSource(stateID: .privateState)
        let downType: CGEventType = isRightClick ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = isRightClick ? .rightMouseUp : .leftMouseUp
        let button: CGMouseButton = isRightClick ? .right : .left

        CGWarpMouseCursorPosition(point)
        if let move = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: button
        ) {
            move.flags = []
            move.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(nanoseconds: 15_000_000)

        if let down = CGEvent(
            mouseEventSource: source,
            mouseType: downType,
            mouseCursorPosition: point,
            mouseButton: button
        ) {
            down.flags = []
            down.setIntegerValueField(.mouseEventClickState, value: 1)
            down.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
            down.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
            down.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(nanoseconds: 40_000_000)

        if let up = CGEvent(
            mouseEventSource: source,
            mouseType: upType,
            mouseCursorPosition: point,
            mouseButton: button
        ) {
            up.flags = []
            up.setIntegerValueField(.mouseEventClickState, value: 1)
            up.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
            up.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
            up.post(tap: .cghidEventTap)
        }

        try? await Task.sleep(nanoseconds: 180_000_000)
    }
}
