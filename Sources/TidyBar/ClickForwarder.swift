/**
 * [INPUT]: 依赖 AppKit、ApplicationServices、CoreGraphics、MenuBarItemMover、MenuBarScanner 与 TidyBarCore（MenuBarItemInfo、MenuBarSection、PermissionManager、SectionLayoutEngine）
 * [OUTPUT]: 提供 ClickForwarder（参考 Ice 实现单图标临时借位 tempShow + 弹窗关闭后静默归位，并在空间不足时降级显露分区）
 * [POS]: TidyBar 的二级栏点击转发引擎，默认保持隐藏区静止零闪现，同时确保稳定唤出目标原生菜单
 * [PROTOCOL]: Update this header on change, then check GEMINI.md
 */

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import TidyBarCore

// ============================================================================
// MARK: - 点击转发结果
// ============================================================================

enum ClickForwardOutcome {
    case forwardedViaTempShow
    case forwardedViaReveal
    case missingAccessibilityPermission
    case targetNotReachable
}

// ============================================================================
// MARK: - 单图标临时借位与点击转发器（Ice 模式）
// ============================================================================

@MainActor
final class ClickForwarder {
    private struct TempShownContext {
        let windowID: CGWindowID
        let ownerPID: pid_t
        let returnDestination: MenuBarItemMover.MoveDestination
        let fallbackDividerID: CGWindowID
        let shownInterfaceWindowID: CGWindowID?
        let createdAt: Date
    }

    private var contexts: [TempShownContext] = []
    private var rehideTimer: Timer?
    private var isRehiding = false

    var hasTempShownItems: Bool {
        !contexts.isEmpty
    }

    /// 优先通过单图标临时借位（保持隐藏分割线不收缩）将目标移入常显区并触发点击，关闭后自动归位
    func forwardClick(
        to item: MenuBarItemInfo,
        isRightClick: Bool,
        menuBarCGMinY: CGFloat,
        screenCGFrame: CGRect,
        auxiliaryTopLeft: CGRect?,
        auxiliaryTopRight: CGRect?,
        toggleWindowID: CGWindowID,
        toggleCGFrame: CGRect,
        hiddenDividerWindowID: CGWindowID,
        hiddenDividerCGFrame: CGRect,
        alwaysHiddenDividerWindowID: CGWindowID?,
        temporarilyReveal: @escaping (MenuBarSection) -> Void
    ) async -> ClickForwardOutcome {
        guard PermissionManager.hasAccessibilityPermission else {
            return .missingAccessibilityPermission
        }

        let mouseButton: CGMouseButton = isRightClick ? .right : .left

        // 1. 目标图标若已在屏幕内且未被刘海遮挡，直接点击
        if let directEntry = currentStatusEntry(for: item.windowID, menuBarCGMinY: menuBarCGMinY),
           directEntry.isOnScreen,
           !isObscuredByNotch(
            frame: directEntry.frame,
            screenCGFrame: screenCGFrame,
            auxiliaryTopLeft: auxiliaryTopLeft,
            auxiliaryTopRight: auxiliaryTopRight
           ) {
            let point = CGPoint(x: directEntry.frame.midX, y: directEntry.frame.midY)
            let ok = await MenuBarItemMover.clickItem(
                windowID: item.windowID,
                ownerPID: item.ownerPID,
                at: point,
                mouseButton: mouseButton
            )
            return ok ? .forwardedViaTempShow : .targetNotReachable
        }

        // 2. 尝试 Ice 风格「单图标临时借位」：仅将目标图标静默借入常显区左侧，不展开其余隐藏图标
        if await attemptTempShowAndClick(
            item: item,
            mouseButton: mouseButton,
            menuBarCGMinY: menuBarCGMinY,
            screenCGFrame: screenCGFrame,
            auxiliaryTopLeft: auxiliaryTopLeft,
            auxiliaryTopRight: auxiliaryTopRight,
            toggleWindowID: toggleWindowID,
            toggleCGFrame: toggleCGFrame,
            hiddenDividerWindowID: hiddenDividerWindowID,
            hiddenDividerCGFrame: hiddenDividerCGFrame,
            alwaysHiddenDividerWindowID: alwaysHiddenDividerWindowID
        ) {
            return .forwardedViaTempShow
        }

        // 3. 当常显区右侧剩余空间不足或单图标移动失败时，降级显露目标分区再点击
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

        try? await Task.sleep(for: .milliseconds(25))
        let clickPoint = CGPoint(x: settledBounds.midX, y: settledBounds.midY)
        let clicked = await MenuBarItemMover.clickItem(
            windowID: item.windowID,
            ownerPID: item.ownerPID,
            at: clickPoint,
            mouseButton: mouseButton
        )
        return clicked ? .forwardedViaReveal : .targetNotReachable
    }

    /// 立即归位全部临时借位图标（在退出、切换原地展开或扫描全量前调用）
    func rehideTempShownItemsNow() async {
        rehideTimer?.invalidate()
        rehideTimer = nil

        guard !contexts.isEmpty, !isRehiding else { return }
        isRehiding = true
        defer { isRehiding = false }

        var remaining: [TempShownContext] = []
        while let context = contexts.popLast() {
            let movedPrimary = await MenuBarItemMover.moveItem(
                windowID: context.windowID,
                ownerPID: context.ownerPID,
                to: context.returnDestination
            )
            if movedPrimary { continue }

            let fallbackDest: MenuBarItemMover.MoveDestination = .leftOfItem(context.fallbackDividerID)
            if fallbackDest != context.returnDestination {
                let movedFallback = await MenuBarItemMover.moveItem(
                    windowID: context.windowID,
                    ownerPID: context.ownerPID,
                    to: fallbackDest
                )
                if movedFallback { continue }
            }
            remaining.append(context)
        }
        contexts = remaining
    }

    // MARK: - Temp Show Pipeline

    private func attemptTempShowAndClick(
        item: MenuBarItemInfo,
        mouseButton: CGMouseButton,
        menuBarCGMinY: CGFloat,
        screenCGFrame: CGRect,
        auxiliaryTopLeft: CGRect?,
        auxiliaryTopRight: CGRect?,
        toggleWindowID: CGWindowID,
        toggleCGFrame: CGRect,
        hiddenDividerWindowID: CGWindowID,
        hiddenDividerCGFrame: CGRect,
        alwaysHiddenDividerWindowID: CGWindowID?
    ) async -> Bool {
        let rawWindows = MenuBarScanner.readRawStatusWindows()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let partitioned = SectionLayoutEngine.partitionItems(
            rawWindows,
            hiddenDividerRightX: hiddenDividerCGFrame.maxX,
            alwaysHiddenDividerRightX: nil,
            ownPID: ownPID,
            menuBarCGMinY: menuBarCGMinY
        )

        let fallbackDividerID = (item.section == .alwaysHidden)
            ? (alwaysHiddenDividerWindowID ?? hiddenDividerWindowID)
            : hiddenDividerWindowID

        let returnDestination = computeReturnDestination(
            item: item,
            rawWindows: rawWindows,
            ownPID: ownPID,
            menuBarCGMinY: menuBarCGMinY,
            hiddenDividerRightX: hiddenDividerCGFrame.maxX,
            fallbackDividerID: fallbackDividerID
        )

        let minSafeX = computeMinSafeX(
            menuBarCGMinY: menuBarCGMinY,
            screenCGFrame: screenCGFrame,
            auxiliaryTopRight: auxiliaryTopRight
        )

        let visibleRaw = partitioned.visible.map { info in
            RawStatusWindow(
                windowID: info.windowID,
                ownerPID: info.ownerPID,
                ownerName: info.ownerName,
                title: info.title,
                cgFrame: info.cgFrame,
                isOnScreen: info.isOnScreen
            )
        }

        guard let anchorID = SectionLayoutEngine.chooseTempShowAnchor(
            visibleItems: visibleRaw,
            toggleCGFrame: toggleCGFrame,
            toggleWindowID: toggleWindowID,
            itemWidth: max(20, item.cgFrame.width),
            minSafeX: minSafeX
        ) else {
            return false
        }

        let initialOnScreenIDs = onScreenWindowIDs(for: item.ownerPID)

        let moved = await MenuBarItemMover.moveItem(
            windowID: item.windowID,
            ownerPID: item.ownerPID,
            to: .leftOfItem(anchorID)
        )
        guard moved else { return false }

        guard let settledFrame = await waitForSettledVisibleBounds(
            windowID: item.windowID,
            menuBarCGMinY: menuBarCGMinY,
            screenCGFrame: screenCGFrame,
            auxiliaryTopLeft: auxiliaryTopLeft,
            auxiliaryTopRight: auxiliaryTopRight
        ) else {
            _ = await MenuBarItemMover.moveItem(
                windowID: item.windowID,
                ownerPID: item.ownerPID,
                to: returnDestination
            )
            return false
        }

        let clickPoint = CGPoint(x: settledFrame.midX, y: settledFrame.midY)
        let clicked = await MenuBarItemMover.clickItem(
            windowID: item.windowID,
            ownerPID: item.ownerPID,
            at: clickPoint,
            mouseButton: mouseButton
        )

        try? await Task.sleep(for: .milliseconds(110))
        let postOnScreenIDs = onScreenWindowIDs(for: item.ownerPID)
        let newlyOpenedID = postOnScreenIDs.subtracting(initialOnScreenIDs).first

        let context = TempShownContext(
            windowID: item.windowID,
            ownerPID: item.ownerPID,
            returnDestination: returnDestination,
            fallbackDividerID: fallbackDividerID,
            shownInterfaceWindowID: newlyOpenedID,
            createdAt: Date()
        )
        contexts.append(context)
        scheduleRehideCheck(delay: 1.5)

        return clicked
    }

    private func computeReturnDestination(
        item: MenuBarItemInfo,
        rawWindows: [RawStatusWindow],
        ownPID: pid_t,
        menuBarCGMinY: CGFloat,
        hiddenDividerRightX: CGFloat,
        fallbackDividerID: CGWindowID
    ) -> MenuBarItemMover.MoveDestination {
        let sameSectionNeighbors = SectionLayoutEngine.partitionItems(
            rawWindows,
            hiddenDividerRightX: hiddenDividerRightX,
            alwaysHiddenDividerRightX: nil,
            ownPID: ownPID,
            menuBarCGMinY: menuBarCGMinY
        ).hidden

        if let index = sameSectionNeighbors.firstIndex(where: { $0.windowID == item.windowID }) {
            if sameSectionNeighbors.indices.contains(index + 1) {
                return .leftOfItem(sameSectionNeighbors[index + 1].windowID)
            }
            if sameSectionNeighbors.indices.contains(index - 1) {
                return .rightOfItem(sameSectionNeighbors[index - 1].windowID)
            }
        }
        return .leftOfItem(fallbackDividerID)
    }

    private func computeMinSafeX(
        menuBarCGMinY: CGFloat,
        screenCGFrame: CGRect,
        auxiliaryTopRight: CGRect?
    ) -> CGFloat {
        let notchBoundary = auxiliaryTopRight.map { $0.minX + 12 } ?? (screenCGFrame.minX + 280)
        let appMenuMaxX = queryApplicationMenuMaxX(screenCGFrame: screenCGFrame, menuBarCGMinY: menuBarCGMinY)
            ?? (screenCGFrame.minX + 360)
        return max(notchBoundary, appMenuMaxX + 8)
    }

    private func queryApplicationMenuMaxX(screenCGFrame: CGRect, menuBarCGMinY: CGFloat) -> CGFloat? {
        let systemWide = AXUIElementCreateSystemWide()
        var elementRef: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(screenCGFrame.minX + 4),
            Float(menuBarCGMinY + 6),
            &elementRef
        )
        guard status == .success, let menuBar = elementRef else { return nil }

        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar, kAXRoleAttribute as CFString, &roleValue) == .success,
              (roleValue as? String) == kAXMenuBarRole else {
            return nil
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return nil
        }

        var maxX: CGFloat?
        for child in children {
            var posValue: CFTypeRef?
            var sizeValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posValue) == .success,
                  AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeValue) == .success,
                  let posAX = posValue, CFGetTypeID(posAX) == AXValueGetTypeID(),
                  let sizeAX = sizeValue, CFGetTypeID(sizeAX) == AXValueGetTypeID() else {
                continue
            }
            var point = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(posAX as! AXValue, .cgPoint, &point)
            AXValueGetValue(sizeAX as! AXValue, .cgSize, &size)
            let rightEdge = point.x + size.width
            if screenCGFrame.contains(CGPoint(x: point.x, y: menuBarCGMinY + 6)) {
                maxX = max(maxX ?? rightEdge, rightEdge)
            }
        }
        return maxX
    }

    private func scheduleRehideCheck(delay: TimeInterval) {
        rehideTimer?.invalidate()
        rehideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.evaluateTempShownRehide()
            }
        }
    }

    private func evaluateTempShownRehide() async {
        guard !contexts.isEmpty else { return }

        // 鼠标按键按住或弹出界面仍在展示时延后归位（最长兜底 30s）
        let isMouseDown = NSEvent.pressedMouseButtons != 0
        let hasActivePopup = contexts.contains { isPopupStillVisible($0) }
        let oldestAge = contexts.map { Date().timeIntervalSince($0.createdAt) }.max() ?? 0

        if (isMouseDown || hasActivePopup) && oldestAge < 30 {
            scheduleRehideCheck(delay: 0.8)
            return
        }

        await rehideTempShownItemsNow()
    }

    private func isPopupStillVisible(_ context: TempShownContext) -> Bool {
        if let popupID = context.shownInterfaceWindowID,
           let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
            let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
            for entry in list {
                guard let id = entry[kCGWindowNumber as String] as? UInt32,
                      CGWindowID(id) == popupID else {
                    continue
                }
                let layer = (entry[kCGWindowLayer as String] as? Int) ?? 0
                if layer == statusLayer {
                    return false
                }
                return true
            }
        }
        return false
    }

    private func onScreenWindowIDs(for pid: pid_t) -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
        var result = Set<CGWindowID>()
        for entry in list {
            guard let owner = entry[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let layer = entry[kCGWindowLayer as String] as? Int, layer != statusLayer,
                  let id = entry[kCGWindowNumber as String] as? UInt32 else {
                continue
            }
            result.insert(CGWindowID(id))
        }
        return result
    }

    // MARK: - Window Settling

    private func waitForSettledVisibleBounds(
        windowID: CGWindowID,
        menuBarCGMinY: CGFloat,
        screenCGFrame: CGRect,
        auxiliaryTopLeft: CGRect?,
        auxiliaryTopRight: CGRect?
    ) async -> CGRect? {
        let visibleMinX = screenCGFrame.minX + 2
        let visibleMaxX = screenCGFrame.maxX - 2

        try? await Task.sleep(for: .milliseconds(30))

        var previousX: CGFloat?
        for _ in 0..<18 {
            if let hit = currentStatusEntry(for: windowID, menuBarCGMinY: menuBarCGMinY),
               hit.isOnScreen,
               hit.frame.minX >= visibleMinX,
               hit.frame.maxX <= visibleMaxX,
               !isObscuredByNotch(
                frame: hit.frame,
                screenCGFrame: screenCGFrame,
                auxiliaryTopLeft: auxiliaryTopLeft,
                auxiliaryTopRight: auxiliaryTopRight
               ) {
                if let prev = previousX, abs(prev - hit.frame.minX) <= 1.0 {
                    return hit.frame
                }
                previousX = hit.frame.minX
            } else {
                previousX = nil
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
        return nil
    }

    private func isObscuredByNotch(
        frame: CGRect,
        screenCGFrame: CGRect,
        auxiliaryTopLeft: CGRect?,
        auxiliaryTopRight: CGRect?
    ) -> Bool {
        SectionLayoutEngine.isPointObscuredByNotch(
            cgPoint: CGPoint(x: frame.midX, y: frame.midY),
            screenCGFrame: screenCGFrame,
            auxiliaryTopLeft: auxiliaryTopLeft,
            auxiliaryTopRight: auxiliaryTopRight
        )
    }

    private func currentStatusEntry(
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
}
