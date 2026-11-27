/**
 * [INPUT]: 依赖 AppKit、CoreGraphics 与 TidyBarCore（MenuBarItemInfo、SectionLayoutEngine）
 * [OUTPUT]: 提供 CapturedMenuBarItem、MenuBarScanResult、FullMenuBarSnapshot 与同步毫秒级 MenuBarScanner（附带 bundleIdentifier 解析）
 * [POS]: TidyBar 的菜单栏图标探测引擎，纯 CGWindowList + 进程信息/图标解析，零异步阻塞与零录屏弹窗
 * [PROTOCOL]: Update this header on change, then check GEMINI.md
 */

import AppKit
import CoreGraphics
import Foundation
import TidyBarCore

// ============================================================================
// MARK: - 抓取结果模型
// ============================================================================

struct CapturedMenuBarItem {
    let info: MenuBarItemInfo
    let image: NSImage
    let isSnapshotFallback: Bool
}

struct MenuBarScanResult {
    let hiddenItems: [CapturedMenuBarItem]
    let alwaysHiddenItems: [CapturedMenuBarItem]
}

struct FullMenuBarSnapshot {
    let visibleItems: [CapturedMenuBarItem]
    let hiddenItems: [CapturedMenuBarItem]
    let alwaysHiddenItems: [CapturedMenuBarItem]
    let driftedBetweenCount: Int
    let menuBarCGMinY: CGFloat
    let screenMaxX: CGFloat
}

// ============================================================================
// MARK: - 状态栏扫描器（纯同步零录屏弹窗）
// ============================================================================

enum MenuBarScanner {
    /// 同步毫秒级扫描当前屏幕隐藏区与总是隐藏区图标（供二级下拉栏即时弹出）
    static func scanHiddenSync(
        menuBarCGMinY: CGFloat,
        hiddenDividerRightX: CGFloat,
        alwaysHiddenDividerRightX: CGFloat?,
        includeAlwaysHidden: Bool
    ) -> MenuBarScanResult {
        let rawWindows = readRawStatusWindows()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let partitioned = SectionLayoutEngine.partitionItems(
            rawWindows,
            hiddenDividerRightX: hiddenDividerRightX,
            alwaysHiddenDividerRightX: alwaysHiddenDividerRightX,
            ownPID: ownPID,
            menuBarCGMinY: menuBarCGMinY
        )

        var bundleCache: [pid_t: String] = [:]
        let hiddenCaptured = enrichWithBundleIdentifiers(partitioned.hidden, cache: &bundleCache)
            .map { makeCapturedItem(info: $0) }
        let alwaysCaptured = includeAlwaysHidden
            ? enrichWithBundleIdentifiers(partitioned.alwaysHidden, cache: &bundleCache)
                .map { makeCapturedItem(info: $0) }
            : []

        return MenuBarScanResult(
            hiddenItems: hiddenCaptured,
            alwaysHiddenItems: alwaysCaptured
        )
    }

    /// 扫描并归类当前屏幕全部三段式菜单栏图标（供「图标管理」页与自动归位器使用）
    static func scanAllSections(
        menuBarCGMinY: CGFloat,
        screenMaxX: CGFloat,
        toggleCGFrame: CGRect,
        hiddenDividerCGFrame: CGRect,
        alwaysHiddenDividerCGFrame: CGRect?
    ) -> FullMenuBarSnapshot {
        let rawWindows = readRawStatusWindows()
        let ownPID = ProcessInfo.processInfo.processIdentifier

        let partitioned = SectionLayoutEngine.partitionItems(
            rawWindows,
            hiddenDividerRightX: hiddenDividerCGFrame.maxX,
            alwaysHiddenDividerRightX: alwaysHiddenDividerCGFrame?.maxX,
            ownPID: ownPID,
            menuBarCGMinY: menuBarCGMinY
        )

        let between = SectionLayoutEngine.itemsBetweenHiddenDividerAndToggle(
            rawWindows,
            toggleCGFrame: toggleCGFrame,
            hiddenDividerCGFrame: hiddenDividerCGFrame,
            menuBarCGMinY: menuBarCGMinY,
            ownPID: ownPID
        )

        var bundleCache: [pid_t: String] = [:]
        return FullMenuBarSnapshot(
            visibleItems: enrichWithBundleIdentifiers(partitioned.visible, cache: &bundleCache)
                .map { makeCapturedItem(info: $0) },
            hiddenItems: enrichWithBundleIdentifiers(partitioned.hidden, cache: &bundleCache)
                .map { makeCapturedItem(info: $0) },
            alwaysHiddenItems: enrichWithBundleIdentifiers(partitioned.alwaysHidden, cache: &bundleCache)
                .map { makeCapturedItem(info: $0) },
            driftedBetweenCount: between.count,
            menuBarCGMinY: menuBarCGMinY,
            screenMaxX: screenMaxX
        )
    }

    static func enrichWithBundleIdentifiers(
        _ items: [MenuBarItemInfo],
        cache: inout [pid_t: String]
    ) -> [MenuBarItemInfo] {
        items.map { info in
            let resolvedBundleID: String?
            if let existing = info.bundleIdentifier {
                resolvedBundleID = existing
            } else if let cached = cache[info.ownerPID] {
                resolvedBundleID = cached.isEmpty ? nil : cached
            } else {
                let id = NSRunningApplication(processIdentifier: info.ownerPID)?.bundleIdentifier ?? ""
                cache[info.ownerPID] = id
                resolvedBundleID = id.isEmpty ? nil : id
            }
            return MenuBarItemInfo(
                windowID: info.windowID,
                ownerPID: info.ownerPID,
                ownerName: info.ownerName,
                bundleIdentifier: resolvedBundleID,
                title: info.title,
                cgFrame: info.cgFrame,
                section: info.section,
                isOnScreen: info.isOnScreen
            )
        }
    }

    static func readRawStatusWindows() -> [RawStatusWindow] {
        guard let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
        var result: [RawStatusWindow] = []
        result.reserveCapacity(48)

        for entry in windowList {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == statusLayer else {
                continue
            }
            guard let windowNumber = entry[kCGWindowNumber as String] as? UInt32,
                  let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }

            let ownerName = (entry[kCGWindowOwnerName as String] as? String) ?? ""
            let title = (entry[kCGWindowName as String] as? String) ?? ""
            let isOnScreen = (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false

            result.append(
                RawStatusWindow(
                    windowID: CGWindowID(windowNumber),
                    ownerPID: ownerPID,
                    ownerName: ownerName,
                    title: title,
                    cgFrame: bounds,
                    isOnScreen: isOnScreen
                )
            )
        }

        return result
    }

    // MARK: - Private Icon Helpers

    private static func makeCapturedItem(info: MenuBarItemInfo) -> CapturedMenuBarItem {
        CapturedMenuBarItem(
            info: info,
            image: resolveAppIcon(for: info),
            isSnapshotFallback: false
        )
    }

    private static func resolveAppIcon(for info: MenuBarItemInfo) -> NSImage {
        if let symbolName = MenuBarItemInfo.suggestedSystemSymbolName(ownerName: info.ownerName, title: info.title) {
            return renderSystemSymbol(name: symbolName, accessibilityLabel: info.displayLabel)
        }

        if let appIcon = NSRunningApplication(processIdentifier: info.ownerPID)?.icon {
            let copy = (appIcon.copy() as? NSImage) ?? appIcon
            copy.size = NSSize(width: 18, height: 18)
            return copy
        }

        return renderSystemSymbol(name: "app.dashed", accessibilityLabel: info.displayLabel)
    }

    private static func renderSystemSymbol(name: String, accessibilityLabel: String) -> NSImage {
        let base = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityLabel)
            ?? NSImage(size: NSSize(width: 18, height: 18))
        let config = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .medium)
        let configured = base.withSymbolConfiguration(config) ?? base
        let copy = (configured.copy() as? NSImage) ?? configured
        copy.isTemplate = true
        copy.size = NSSize(width: 18, height: 18)
        return copy
    }
}
