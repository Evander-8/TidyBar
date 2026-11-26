/**
 * [INPUT]: 依赖 CoreGraphics、Foundation 与 Models（MenuBarItemInfo、MenuBarSection）
 * [OUTPUT]: 提供 SectionLayoutEngine 几何引擎（Preferred Position 预设位序校验、防自锁顺序校验、按 WindowID 识别自身窗口与出屏硬守卫、三段式分区、临时借位锚点选择、二级下拉栏定位、刘海盲区判定）
 * [POS]: TidyBarCore 的纯几何算法中枢，所有状态栏边界计算与防自锁不变量均在此集中验证
 * [PROTOCOL]: Update this header on change, then check GEMINI.md
 */

import CoreGraphics
import Foundation

// ============================================================================
// MARK: - 输入输出数据结构
// ============================================================================

public enum DividerOrderValidation: Equatable, Sendable {
    case valid
    case hiddenDividerRightOfToggle
    case alwaysHiddenDividerRightOfHidden
}

public struct RawStatusWindow: Equatable, Sendable {
    public let windowID: CGWindowID
    public let ownerPID: pid_t
    public let ownerName: String
    public let title: String
    public let cgFrame: CGRect
    public let isOnScreen: Bool

    public init(
        windowID: CGWindowID,
        ownerPID: pid_t,
        ownerName: String,
        title: String,
        cgFrame: CGRect,
        isOnScreen: Bool
    ) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.title = title
        self.cgFrame = cgFrame
        self.isOnScreen = isOnScreen
    }
}

public struct PartitionedMenuBarItems: Equatable, Sendable {
    public let visible: [MenuBarItemInfo]
    public let hidden: [MenuBarItemInfo]
    public let alwaysHidden: [MenuBarItemInfo]

    public init(
        visible: [MenuBarItemInfo],
        hidden: [MenuBarItemInfo],
        alwaysHidden: [MenuBarItemInfo]
    ) {
        self.visible = visible
        self.hidden = hidden
        self.alwaysHidden = alwaysHidden
    }
}

// ============================================================================
// MARK: - 布局与几何计算引擎
// ============================================================================

public enum SectionLayoutEngine {
    /// 校验 UserDefaults 中 macOS 持久化的 NSStatusItem Preferred Position 是否满足安全有序：
    /// 注意 macOS 从屏幕右缘向左计数（数值越小越靠右），必须满足 0 <= toggle < hidden (< always)。
    public static func arePreferredPositionsOrdered(
        togglePos: Double?,
        hiddenPos: Double?,
        alwaysPos: Double?,
        minGap: Double = 0.5
    ) -> Bool {
        guard let togglePos, let hiddenPos else { return false }
        guard togglePos >= 0, togglePos < 2000 else { return false }
        guard hiddenPos >= 0, hiddenPos < 3000 else { return false }
        guard hiddenPos >= togglePos + minGap else { return false }

        if let alwaysPos {
            guard alwaysPos >= hiddenPos + minGap, alwaysPos < 5000 else {
                return false
            }
        }
        return true
    }

    /// 校验主开关与分割线水平顺序：[总是隐藏分割线] <= [隐藏分割线] <= [主按钮]
    /// 折叠前必须通过此校验，否则撑开分割线会把主按钮本身推出屏幕导致无法点击。
    public static func validateDividerOrder(
        toggleFrame: CGRect,
        hiddenDividerFrame: CGRect,
        alwaysHiddenDividerFrame: CGRect?,
        tolerance: CGFloat = 2.0
    ) -> DividerOrderValidation {
        if hiddenDividerFrame.maxX > toggleFrame.minX + tolerance {
            return .hiddenDividerRightOfToggle
        }
        if let alwaysFrame = alwaysHiddenDividerFrame,
           alwaysFrame.maxX > hiddenDividerFrame.minX + tolerance {
            return .alwaysHiddenDividerRightOfHidden
        }
        return .valid
    }

    /// 将 CGWindowList 扫描到的状态栏窗口按分割线位置划入三段式分区，并剔除系统占位、非目标屏幕与自身窗口
    public static func partitionItems(
        _ rawItems: [RawStatusWindow],
        hiddenDividerRightX: CGFloat,
        alwaysHiddenDividerRightX: CGFloat?,
        ownPID: pid_t,
        menuBarCGMinY: CGFloat? = nil,
        verticalTolerance: CGFloat = 10.0
    ) -> PartitionedMenuBarItems {
        var visible: [MenuBarItemInfo] = []
        var hidden: [MenuBarItemInfo] = []
        var alwaysHidden: [MenuBarItemInfo] = []

        for raw in rawItems {
            guard isValidStatusWindow(
                raw,
                ownPID: ownPID,
                menuBarCGMinY: menuBarCGMinY,
                verticalTolerance: verticalTolerance
            ) else { continue }

            let midX = raw.cgFrame.midX
            let section: MenuBarSection
            if let alwaysRightX = alwaysHiddenDividerRightX, midX <= alwaysRightX {
                section = .alwaysHidden
            } else if midX <= hiddenDividerRightX {
                section = .hidden
            } else {
                section = .visible
            }

            let info = MenuBarItemInfo(
                windowID: raw.windowID,
                ownerPID: raw.ownerPID,
                ownerName: raw.ownerName,
                title: raw.title,
                cgFrame: raw.cgFrame,
                section: section,
                isOnScreen: raw.isOnScreen
            )

            switch section {
            case .visible:
                visible.append(info)
            case .hidden:
                hidden.append(info)
            case .alwaysHidden:
                alwaysHidden.append(info)
            }
        }

        visible.sort { $0.cgFrame.minX < $1.cgFrame.minX }
        hidden.sort { $0.cgFrame.minX < $1.cgFrame.minX }
        alwaysHidden.sort { $0.cgFrame.minX < $1.cgFrame.minX }

        return PartitionedMenuBarItems(
            visible: visible,
            hidden: hidden,
            alwaysHidden: alwaysHidden
        )
    }

    /// 严格按真实 CGWindowID 识别自身 2-3 个状态栏窗口（绝不按 maxX 排序盲猜，防止倒置时身份互换绕过防自锁）
    public static func classifyOwnStatusWindows(
        _ rawItems: [RawStatusWindow],
        ownPID: pid_t,
        menuBarCGMinY: CGFloat,
        toggleWindowID: CGWindowID,
        hiddenDividerWindowID: CGWindowID,
        alwaysHiddenDividerWindowID: CGWindowID?,
        verticalTolerance: CGFloat = 10.0
    ) -> (toggle: RawStatusWindow?, hiddenDivider: RawStatusWindow?, alwaysHiddenDivider: RawStatusWindow?) {
        let own = rawItems.filter {
            $0.ownerPID == ownPID
                && abs($0.cgFrame.minY - menuBarCGMinY) <= verticalTolerance
                && $0.cgFrame.height > 10
                && $0.cgFrame.height <= 48
                && $0.cgFrame.width >= 4
        }

        let toggle = own.first { $0.windowID == toggleWindowID }
        let hidden = own.first { $0.windowID == hiddenDividerWindowID }
        let always = alwaysHiddenDividerWindowID.flatMap { targetID in
            own.first { $0.windowID == targetID }
        }
        return (toggle, hidden, always)
    }

    /// 判定主开关是否已被推出当前屏幕可见区间外（防自锁硬守卫）
    public static func isToggleOffScreen(
        toggleCGFrame: CGRect,
        screenCGFrame: CGRect
    ) -> Bool {
        toggleCGFrame.maxX <= screenCGFrame.minX + 2 || toggleCGFrame.minX >= screenCGFrame.maxX - 2
    }

    /// 计算将图标通过 Command+Drag 移入目标分区时在 CG 坐标系下的落点
    public static func computeMoveDestination(
        targetSection: MenuBarSection,
        toggleCGFrame: CGRect,
        hiddenDividerCGFrame: CGRect,
        alwaysHiddenDividerCGFrame: CGRect?,
        attemptOffset: CGFloat = 0
    ) -> CGPoint {
        let y = toggleCGFrame.midY
        switch targetSection {
        case .visible:
            return CGPoint(x: toggleCGFrame.maxX + 12 + attemptOffset, y: y)

        case .hidden:
            if let alwaysFrame = alwaysHiddenDividerCGFrame {
                let gap = hiddenDividerCGFrame.minX - alwaysFrame.maxX
                if gap >= 8 {
                    let center = (alwaysFrame.maxX + hiddenDividerCGFrame.minX) / 2
                    let nudge = attemptOffset == 0 ? 0 : min(gap * 0.25, attemptOffset * 0.4)
                    return CGPoint(x: center + nudge, y: y)
                }
                // 两分割线紧贴时，落点贴近 hiddenDivider 左侧内侧，由 WindowServer 撑开两线之间空隙
                return CGPoint(x: hiddenDividerCGFrame.minX - 2 - attemptOffset * 0.3, y: y)
            }
            return CGPoint(x: hiddenDividerCGFrame.minX - 10 - attemptOffset, y: y)

        case .alwaysHidden:
            let anchor = alwaysHiddenDividerCGFrame ?? hiddenDividerCGFrame
            return CGPoint(x: anchor.minX - 12 - attemptOffset, y: y)
        }
    }

    /// 计算「单图标临时借位」在主开关右侧的临时停靠坐标（钳制在屏幕右缘内侧，避免撞到系统固定时钟）
    public static func computeBorrowDestination(
        toggleCGFrame: CGRect,
        screenMaxX: CGFloat,
        attemptOffset: CGFloat = 0
    ) -> CGPoint {
        let rawX = toggleCGFrame.maxX + 10 + attemptOffset
        let safeMaxX = max(toggleCGFrame.maxX + 4, screenMaxX - 16)
        return CGPoint(x: min(rawX, safeMaxX), y: toggleCGFrame.midY)
    }

    /// 检测夹在「|」分割线与「TidyBar 主开关」之间的漂移图标（因手误拖开主开关导致未被隐藏）
    public static func itemsBetweenHiddenDividerAndToggle(
        _ rawItems: [RawStatusWindow],
        toggleCGFrame: CGRect,
        hiddenDividerCGFrame: CGRect,
        menuBarCGMinY: CGFloat,
        ownPID: pid_t,
        verticalTolerance: CGFloat = 10.0
    ) -> [RawStatusWindow] {
        guard hiddenDividerCGFrame.maxX < toggleCGFrame.minX else { return [] }
        return rawItems
            .filter { raw in
                guard isValidStatusWindow(
                    raw,
                    ownPID: ownPID,
                    menuBarCGMinY: menuBarCGMinY,
                    verticalTolerance: verticalTolerance
                ) else { return false }
                let midX = raw.cgFrame.midX
                return midX > hiddenDividerCGFrame.maxX && midX < toggleCGFrame.minX
            }
            .sorted { $0.cgFrame.minX < $1.cgFrame.minX }
    }

    /// 判断是否为系统强制钉在最右侧不可通过 Command+Drag 移走或隐藏的固定项（时钟、控制中心主体、Siri、屏幕录制指示等）
    public static func isLikelySystemPinnedItem(
        ownerName: String,
        title: String,
        cgFrame: CGRect,
        screenMaxX: CGFloat
    ) -> Bool {
        let trimmedOwner = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerTitle = title.lowercased()

        if trimmedOwner == "Siri" || (trimmedOwner.contains("SystemUIServer") && lowerTitle == "siri") {
            return true
        }

        let isControlCenter = trimmedOwner == "控制中心"
            || trimmedOwner == "ControlCenter"
            || trimmedOwner == "Control Center"
        guard isControlCenter else { return false }

        if screenMaxX - cgFrame.maxX < 8 {
            return true
        }
        let pinnedKeywords = [
            "clock", "bentobox", "时钟",
            "audiovideomodule", "facetime", "musicrecognition"
        ]
        if pinnedKeywords.contains(where: { lowerTitle.contains($0) }) {
            return true
        }
        return false
    }

    /// 为单图标临时借位选出最左侧且左侧空间足够（不会撞入刘海或应用菜单）的可见锚点窗口
    public static func chooseTempShowAnchor(
        visibleItems: [RawStatusWindow],
        toggleCGFrame: CGRect,
        toggleWindowID: CGWindowID,
        itemWidth: CGFloat,
        minSafeX: CGFloat
    ) -> CGWindowID? {
        var candidates: [(windowID: CGWindowID, minX: CGFloat)] = visibleItems
            .filter { $0.isOnScreen && $0.cgFrame.minX >= toggleCGFrame.minX - 2 }
            .map { ($0.windowID, $0.cgFrame.minX) }
        candidates.append((toggleWindowID, toggleCGFrame.minX))
        candidates.sort { $0.minX < $1.minX }

        return candidates.first { $0.minX - itemWidth >= minSafeX }?.windowID
    }

    /// 计算二级下拉栏在 AppKit 坐标系下的窗口矩形（自动居中对齐并严格钳制在屏幕可见区内）
    public static func computeSecondaryBarFrame(
        anchorRect: CGRect,
        itemCount: Int,
        hasSectionSeparator: Bool,
        showsPermissionBanner: Bool,
        itemSize: CGSize = CGSize(width: 30, height: 28),
        itemSpacing: CGFloat = 6,
        padding: CGFloat = 10,
        maxColumns: Int = 12,
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> CGRect {
        let clampedMaxCols = max(1, maxColumns)
        let effectiveCount = max(0, itemCount)

        let panelWidth: CGFloat
        let gridHeight: CGFloat

        if effectiveCount == 0 {
            panelWidth = 264
            gridHeight = 36
        } else {
            let columns = min(effectiveCount, clampedMaxCols)
            let rows = Int(ceil(Double(effectiveCount) / Double(clampedMaxCols)))
            let separatorExtra: CGFloat = (hasSectionSeparator && rows == 1) ? 14 : 0
            let rawWidth = CGFloat(columns) * itemSize.width
                + CGFloat(max(0, columns - 1)) * itemSpacing
                + padding * 2
                + separatorExtra
            panelWidth = max(140, min(rawWidth, visibleFrame.width - 16))
            gridHeight = CGFloat(rows) * itemSize.height
                + CGFloat(max(0, rows - 1)) * itemSpacing
        }

        let bannerHeight: CGFloat = showsPermissionBanner ? 34 : 0
        let panelHeight = padding * 2 + gridHeight + bannerHeight

        // 默认水平居中对齐于触发按钮中心，垂直紧贴菜单栏下方
        let preferredX = anchorRect.midX - panelWidth / 2
        let safeMinX = visibleFrame.minX + 8
        let safeMaxX = max(safeMinX, visibleFrame.maxX - panelWidth - 8)
        let originX = min(max(preferredX, safeMinX), safeMaxX)

        // AppKit 坐标系原点在左下角；visibleFrame.maxY 即菜单栏底缘
        let topLimit = min(visibleFrame.maxY, screenFrame.maxY - 24)
        let originY = max(visibleFrame.minY + 8, topLimit - 6 - panelHeight)

        return CGRect(
            x: round(originX),
            y: round(originY),
            width: round(panelWidth),
            height: round(panelHeight)
        )
    }

    /// 检测给定 CG 坐标点是否落入 MacBook 刘海盲区
    public static func isPointObscuredByNotch(
        cgPoint: CGPoint,
        screenCGFrame: CGRect,
        auxiliaryTopLeft: CGRect?,
        auxiliaryTopRight: CGRect?
    ) -> Bool {
        guard let left = auxiliaryTopLeft, let right = auxiliaryTopRight else {
            return false
        }
        guard screenCGFrame.contains(cgPoint) else { return false }

        // auxiliaryTopLeft / Right 为 AppKit 或相对同一屏幕 X 轴的左右可显示条带
        let notchMinX = left.maxX
        let notchMaxX = right.minX
        guard notchMaxX > notchMinX else { return false }

        let menuBarMaxY = screenCGFrame.minY + max(left.height, right.height)
        return cgPoint.x >= notchMinX && cgPoint.x <= notchMaxX && cgPoint.y <= menuBarMaxY
    }

    // MARK: - Private Helpers

    private static func isValidStatusWindow(
        _ raw: RawStatusWindow,
        ownPID: pid_t,
        menuBarCGMinY: CGFloat?,
        verticalTolerance: CGFloat
    ) -> Bool {
        guard raw.ownerPID != ownPID else { return false }
        guard raw.ownerName != "Window Server" else { return false }
        guard raw.cgFrame.width > 2, raw.cgFrame.width <= 400 else { return false }
        guard raw.cgFrame.height > 10, raw.cgFrame.height <= 48 else { return false }
        // 过滤未显示且停留在原点 (0, 0) 的幽灵占位窗口（例如部分多进程代理未激活的状态栏项）
        if !raw.isOnScreen && raw.cgFrame.minX == 0 && raw.cgFrame.minY == 0 {
            return false
        }
        if let targetY = menuBarCGMinY, abs(raw.cgFrame.minY - targetY) > verticalTolerance {
            return false
        }
        return true
    }
}
