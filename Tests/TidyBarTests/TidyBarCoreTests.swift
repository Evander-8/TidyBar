/**
 * [INPUT]: 依赖 XCTest 与 TidyBarCore（SectionLayoutEngine、SettingsStore、HotkeyCombo、TidyBarSettings）
 * [OUTPUT]: 提供 TidyBarCoreTests 自动化单元测试套件，验证防自锁校验、分区过滤、二级栏定位、刘海检测与配置存储
 * [POS]: Tests/TidyBarTests 的唯一核心测试入口
 * [PROTOCOL]: Update this header on change, then check GEMINI.md
 */

import CoreGraphics
import Foundation
import XCTest
@testable import TidyBarCore

final class TidyBarCoreTests: XCTestCase {

    // =========================================================================
    // MARK: - SectionLayoutEngine: 防自锁与分区测试
    // =========================================================================

    func testValidateDividerOrderAcceptsNormalOrder() {
        let always = CGRect(x: 900, y: 0, width: 12, height: 24)
        let hidden = CGRect(x: 1100, y: 0, width: 10, height: 24)
        let toggle = CGRect(x: 1250, y: 0, width: 24, height: 24)

        let result = SectionLayoutEngine.validateDividerOrder(
            toggleFrame: toggle,
            hiddenDividerFrame: hidden,
            alwaysHiddenDividerFrame: always
        )
        XCTAssertEqual(result, .valid)
    }

    func testValidateDividerOrderDetectsHiddenDividerRightOfToggle() {
        let hidden = CGRect(x: 1280, y: 0, width: 10, height: 24)
        let toggle = CGRect(x: 1250, y: 0, width: 24, height: 24)

        let result = SectionLayoutEngine.validateDividerOrder(
            toggleFrame: toggle,
            hiddenDividerFrame: hidden,
            alwaysHiddenDividerFrame: nil
        )
        XCTAssertEqual(result, .hiddenDividerRightOfToggle)
    }

    func testValidateDividerOrderDetectsAlwaysDividerRightOfHidden() {
        let always = CGRect(x: 1140, y: 0, width: 12, height: 24)
        let hidden = CGRect(x: 1100, y: 0, width: 10, height: 24)
        let toggle = CGRect(x: 1250, y: 0, width: 24, height: 24)

        let result = SectionLayoutEngine.validateDividerOrder(
            toggleFrame: toggle,
            hiddenDividerFrame: hidden,
            alwaysHiddenDividerFrame: always
        )
        XCTAssertEqual(result, .alwaysHiddenDividerRightOfHidden)
    }

    func testPartitionItemsClassifiesThreeSectionsAndFiltersInvalidWindows() {
        let ownPID: pid_t = 4242
        let raw: [RawStatusWindow] = [
            // 自身窗口应过滤
            RawStatusWindow(windowID: 1, ownerPID: ownPID, ownerName: "TidyBar", title: "", cgFrame: CGRect(x: 1200, y: 0, width: 24, height: 24), isOnScreen: true),
            // 极窄占位窗口应过滤
            RawStatusWindow(windowID: 2, ownerPID: 100, ownerName: "Phantom", title: "", cgFrame: CGRect(x: 1100, y: 0, width: 1, height: 24), isOnScreen: false),
            // Window Server 占位条应过滤
            RawStatusWindow(windowID: 3, ownerPID: 101, ownerName: "Window Server", title: "Menubar", cgFrame: CGRect(x: 0, y: 0, width: 1440, height: 24), isOnScreen: true),
            // 总是隐藏区
            RawStatusWindow(windowID: 10, ownerPID: 201, ownerName: "Docker", title: "", cgFrame: CGRect(x: 800, y: 0, width: 26, height: 24), isOnScreen: false),
            // 隐藏区（刻意乱序以验证按 minX 排序）
            RawStatusWindow(windowID: 12, ownerPID: 203, ownerName: "Raycast", title: "", cgFrame: CGRect(x: 1140, y: 0, width: 24, height: 24), isOnScreen: true),
            RawStatusWindow(windowID: 11, ownerPID: 202, ownerName: "Tailscale", title: "", cgFrame: CGRect(x: 1030, y: 0, width: 24, height: 24), isOnScreen: true),
            // 常显区
            RawStatusWindow(windowID: 13, ownerPID: 204, ownerName: "ControlCenter", title: "Wi-Fi", cgFrame: CGRect(x: 1310, y: 0, width: 26, height: 24), isOnScreen: true)
        ]

        let partitioned = SectionLayoutEngine.partitionItems(
            raw,
            hiddenDividerRightX: 1200,
            alwaysHiddenDividerRightX: 900,
            ownPID: ownPID
        )

        XCTAssertEqual(partitioned.alwaysHidden.map(\.ownerName), ["Docker"])
        XCTAssertEqual(partitioned.hidden.map(\.ownerName), ["Tailscale", "Raycast"])
        XCTAssertEqual(partitioned.visible.map(\.ownerName), ["ControlCenter"])
    }

    // =========================================================================
    // MARK: - SectionLayoutEngine: 二级栏几何与刘海检测测试
    // =========================================================================

    func testSecondaryBarFrameClampsToRightScreenEdge() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 876)
        let anchorRect = CGRect(x: 1410, y: 876, width: 24, height: 24)

        let panelRect = SectionLayoutEngine.computeSecondaryBarFrame(
            anchorRect: anchorRect,
            itemCount: 8,
            hasSectionSeparator: true,
            showsPermissionBanner: false,
            maxColumns: 12,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )

        XCTAssertLessThanOrEqual(panelRect.maxX, visibleFrame.maxX - 8)
        XCTAssertGreaterThanOrEqual(panelRect.minX, visibleFrame.minX + 8)
        XCTAssertLessThan(panelRect.maxY, visibleFrame.maxY)
    }

    func testSecondaryBarFrameWrapsIntoMultipleRows() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 876)
        let anchorRect = CGRect(x: 1100, y: 876, width: 24, height: 24)

        let oneRow = SectionLayoutEngine.computeSecondaryBarFrame(
            anchorRect: anchorRect,
            itemCount: 6,
            hasSectionSeparator: false,
            showsPermissionBanner: false,
            maxColumns: 6,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )
        let twoRows = SectionLayoutEngine.computeSecondaryBarFrame(
            anchorRect: anchorRect,
            itemCount: 10,
            hasSectionSeparator: false,
            showsPermissionBanner: false,
            maxColumns: 6,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )

        XCTAssertGreaterThan(twoRows.height, oneRow.height)
    }

    func testNotchDetectionIdentifiesCenterCutout() {
        let screenCG = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let auxLeft = CGRect(x: 0, y: 945, width: 650, height: 37)
        let auxRight = CGRect(x: 862, y: 945, width: 650, height: 37)

        XCTAssertTrue(
            SectionLayoutEngine.isPointObscuredByNotch(
                cgPoint: CGPoint(x: 750, y: 18),
                screenCGFrame: screenCG,
                auxiliaryTopLeft: auxLeft,
                auxiliaryTopRight: auxRight
            )
        )
        XCTAssertFalse(
            SectionLayoutEngine.isPointObscuredByNotch(
                cgPoint: CGPoint(x: 1100, y: 18),
                screenCGFrame: screenCG,
                auxiliaryTopLeft: auxLeft,
                auxiliaryTopRight: auxRight
            )
        )
    }

    // =========================================================================
    // MARK: - SettingsStore & HotkeyCombo 测试
    // =========================================================================

    func testSettingsStorePersistenceAndReset() throws {
        let suiteName = "com.tidybar.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(store.settings, .default)

        store.update {
            $0.displayMode = .inline
            $0.autoRehideDelay = .thirty
            $0.enableAlwaysHiddenSection = false
            $0.secondaryBarMaxColumns = 99 // 应钳制到 20
        }

        let reloaded = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.settings.displayMode, .inline)
        XCTAssertEqual(reloaded.settings.autoRehideDelay, .thirty)
        XCTAssertFalse(reloaded.settings.enableAlwaysHiddenSection)
        XCTAssertEqual(reloaded.settings.secondaryBarMaxColumns, 20)

        reloaded.resetToDefaults()
        XCTAssertEqual(reloaded.settings, .default)
    }

    func testHotkeyComboFormattingAndCodableRoundtrip() throws {
        let combo = HotkeyCombo.defaultToggle
        XCTAssertEqual(combo.displayString, "⌃⌥H")

        let data = try JSONEncoder().encode(combo)
        let decoded = try JSONDecoder().decode(HotkeyCombo.self, from: data)
        XCTAssertEqual(decoded, combo)
    }

    // =========================================================================
    // MARK: - 多显示器过滤、移动坐标、漂移检测与旧配置兼容测试
    // =========================================================================

    func testPartitionItemsFiltersSecondaryMonitorDuplicatesByMenuBarCGMinY() {
        let ownPID: pid_t = 4242
        let raw: [RawStatusWindow] = [
            // 主屏状态栏窗口（y = 0）
            RawStatusWindow(windowID: 1, ownerPID: 300, ownerName: "WeChat", title: "", cgFrame: CGRect(x: 1506, y: 0, width: 56, height: 43), isOnScreen: true),
            RawStatusWindow(windowID: 2, ownerPID: 301, ownerName: "FlClash", title: "", cgFrame: CGRect(x: 1120, y: 0, width: 34, height: 43), isOnScreen: true),
            // 副屏状态栏副本（y = 89，负 X 坐标）与非菜单栏弹窗（y = 915）均应被过滤
            RawStatusWindow(windowID: 3, ownerPID: 300, ownerName: "WeChat", title: "", cgFrame: CGRect(x: -296, y: 89, width: 56, height: 24), isOnScreen: true),
            RawStatusWindow(windowID: 4, ownerPID: 302, ownerName: "LinkedNotesUIService", title: "", cgFrame: CGRect(x: 1546, y: 915, width: 254, height: 40), isOnScreen: false)
        ]

        let partitioned = SectionLayoutEngine.partitionItems(
            raw,
            hiddenDividerRightX: 1200,
            alwaysHiddenDividerRightX: 1000,
            ownPID: ownPID,
            menuBarCGMinY: 0
        )

        XCTAssertEqual(partitioned.alwaysHidden.count, 0)
        XCTAssertEqual(partitioned.hidden.map(\.ownerName), ["FlClash"])
        XCTAssertEqual(partitioned.visible.map(\.ownerName), ["WeChat"])
    }

    func testClassifyOwnStatusWindowsMatchesExactWindowIDsWithoutSwappingInvertedOrder() {
        let ownPID: pid_t = 999
        let screenCG = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let raw: [RawStatusWindow] = [
            // 副屏自身副本应被忽略
            RawStatusWindow(windowID: 50, ownerPID: ownPID, ownerName: "TidyBar", title: "", cgFrame: CGRect(x: -5474, y: 89, width: 40, height: 24), isOnScreen: false),
            // 模拟真实事故现场：hiddenDivider (51) 跑到了 toggle (49) 右侧，把 toggle 挤出屏幕左缘
            RawStatusWindow(windowID: 53, ownerPID: ownPID, ownerName: "TidyBar", title: "", cgFrame: CGRect(x: -8884, y: 0, width: 5016, height: 43), isOnScreen: false),
            RawStatusWindow(windowID: 51, ownerPID: ownPID, ownerName: "TidyBar", title: "", cgFrame: CGRect(x: -3632, y: 0, width: 5016, height: 43), isOnScreen: false),
            RawStatusWindow(windowID: 49, ownerPID: ownPID, ownerName: "TidyBar", title: "", cgFrame: CGRect(x: -3672, y: 0, width: 40, height: 43), isOnScreen: false)
        ]

        let classified = SectionLayoutEngine.classifyOwnStatusWindows(
            raw,
            ownPID: ownPID,
            menuBarCGMinY: 0,
            toggleWindowID: 49,
            hiddenDividerWindowID: 51,
            alwaysHiddenDividerWindowID: 53
        )
        XCTAssertEqual(classified.toggle?.windowID, 49)
        XCTAssertEqual(classified.hiddenDivider?.windowID, 51)
        XCTAssertEqual(classified.alwaysHiddenDivider?.windowID, 53)

        let validation = SectionLayoutEngine.validateDividerOrder(
            toggleFrame: classified.toggle!.cgFrame,
            hiddenDividerFrame: classified.hiddenDivider!.cgFrame,
            alwaysHiddenDividerFrame: classified.alwaysHiddenDivider?.cgFrame
        )
        XCTAssertEqual(validation, .hiddenDividerRightOfToggle)
        XCTAssertTrue(SectionLayoutEngine.isToggleOffScreen(toggleCGFrame: classified.toggle!.cgFrame, screenCGFrame: screenCG))
    }

    func testComputeMoveDestinationTargetsExactZones() {
        let toggle = CGRect(x: 1240, y: 0, width: 24, height: 43)
        let hidden = CGRect(x: 1180, y: 0, width: 16, height: 43)
        let alwaysTight = CGRect(x: 1160, y: 0, width: 16, height: 43)

        let toVisible = SectionLayoutEngine.computeMoveDestination(
            targetSection: .visible,
            toggleCGFrame: toggle,
            hiddenDividerCGFrame: hidden,
            alwaysHiddenDividerCGFrame: alwaysTight
        )
        XCTAssertGreaterThan(toVisible.x, toggle.maxX)

        let toHiddenTight = SectionLayoutEngine.computeMoveDestination(
            targetSection: .hidden,
            toggleCGFrame: toggle,
            hiddenDividerCGFrame: hidden,
            alwaysHiddenDividerCGFrame: alwaysTight
        )
        XCTAssertGreaterThan(toHiddenTight.x, alwaysTight.maxX)
        XCTAssertLessThan(toHiddenTight.x, hidden.minX)

        let toAlways = SectionLayoutEngine.computeMoveDestination(
            targetSection: .alwaysHidden,
            toggleCGFrame: toggle,
            hiddenDividerCGFrame: hidden,
            alwaysHiddenDividerCGFrame: alwaysTight
        )
        XCTAssertLessThan(toAlways.x, alwaysTight.minX)
    }

    func testDriftedItemsBetweenDividerAndToggleAndPinnedCheck() {
        let ownPID: pid_t = 999
        let toggle = CGRect(x: 1242, y: 0, width: 24, height: 43)
        let hidden = CGRect(x: 1019, y: 0, width: 16, height: 43)
        let raw: [RawStatusWindow] = [
            RawStatusWindow(windowID: 10, ownerPID: 100, ownerName: "TextInputMenuAgent", title: "", cgFrame: CGRect(x: 1198, y: 0, width: 44, height: 43), isOnScreen: true),
            RawStatusWindow(windowID: 11, ownerPID: 101, ownerName: "QuickSnap", title: "", cgFrame: CGRect(x: 1282, y: 0, width: 38, height: 43), isOnScreen: true)
        ]

        let between = SectionLayoutEngine.itemsBetweenHiddenDividerAndToggle(
            raw,
            toggleCGFrame: toggle,
            hiddenDividerCGFrame: hidden,
            menuBarCGMinY: 0,
            ownPID: ownPID
        )
        XCTAssertEqual(between.map(\.ownerName), ["TextInputMenuAgent"])

        XCTAssertTrue(
            SectionLayoutEngine.isLikelySystemPinnedItem(
                ownerName: "控制中心",
                title: "",
                cgFrame: CGRect(x: 1672, y: 0, width: 130, height: 43),
                screenMaxX: 1800
            )
        )
        XCTAssertFalse(
            SectionLayoutEngine.isLikelySystemPinnedItem(
                ownerName: "QuickSnap",
                title: "",
                cgFrame: CGRect(x: 1282, y: 0, width: 38, height: 43),
                screenMaxX: 1800
            )
        )
    }

    func testLegacySettingsJSONDecodesSafely() throws {
        let legacyJSON = """
        {
            "displayMode": "inline",
            "autoRehideDelay": 5,
            "rehideOnFocusLoss": false,
            "enableAlwaysHiddenSection": true,
            "toggleIconStyle": "dot",
            "dividerStyle": "dot",
            "hotkeyEnabled": true,
            "toggleHotkey": { "keyCode": 4, "modifiers": 6144, "displayString": "⌃⌥H" },
            "secondaryBarMaxColumns": 10
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(TidyBarSettings.self, from: legacyJSON)
        XCTAssertEqual(decoded.displayMode, .inline)
        XCTAssertEqual(decoded.autoRehideDelay, .five)
        XCTAssertTrue(decoded.hasOpenedInitialSettings)
    }

    func testPartitionItemsFiltersOriginGhostWindows() {
        let raw: [RawStatusWindow] = [
            // 未显示且位于 (0, 0) 原点的幽灵窗口应被过滤
            RawStatusWindow(windowID: 283, ownerPID: 11678, ownerName: "WPS Office Service", title: "", cgFrame: CGRect(x: 0, y: 0, width: 32, height: 43), isOnScreen: false),
            // 真正被折叠推出屏幕的隐藏图标（x < 0）应保留
            RawStatusWindow(windowID: 282, ownerPID: 11678, ownerName: "WPS Office Service", title: "", cgFrame: CGRect(x: -8935, y: 0, width: 34, height: 43), isOnScreen: false)
        ]

        let partitioned = SectionLayoutEngine.partitionItems(
            raw,
            hiddenDividerRightX: 1000,
            alwaysHiddenDividerRightX: nil,
            ownPID: 999,
            menuBarCGMinY: 0
        )

        XCTAssertEqual(partitioned.hidden.map(\.windowID), [282])
        XCTAssertTrue(partitioned.visible.isEmpty)
    }

    func testComputeBorrowDestinationPlacesNextToToggleAndClampsRightEdge() {
        let toggle = CGRect(x: 1362, y: 0, width: 24, height: 43)
        let normalDest = SectionLayoutEngine.computeBorrowDestination(
            toggleCGFrame: toggle,
            screenMaxX: 1800
        )
        XCTAssertGreaterThan(normalDest.x, toggle.maxX)
        XCTAssertLessThan(normalDest.x, 1800 - 16)
        XCTAssertEqual(normalDest.y, toggle.midY)

        let tightToggle = CGRect(x: 1760, y: 0, width: 24, height: 43)
        let clampedDest = SectionLayoutEngine.computeBorrowDestination(
            toggleCGFrame: tightToggle,
            screenMaxX: 1800,
            attemptOffset: 40
        )
        XCTAssertLessThanOrEqual(clampedDest.x, 1800 - 12)
    }

    func testSystemMenuBarItemLocalizationAndPinnedDetection() {
        let display = MenuBarItemInfo(
            windowID: 1,
            ownerPID: 10,
            ownerName: "控制中心",
            title: "Display",
            cgFrame: CGRect(x: 1526, y: 0, width: 36, height: 43),
            section: .visible,
            isOnScreen: true
        )
        XCTAssertEqual(display.displayLabel, "显示器")
        XCTAssertEqual(MenuBarItemInfo.suggestedSystemSymbolName(ownerName: display.ownerName, title: display.title), "display")

        let battery = MenuBarItemInfo(
            windowID: 2,
            ownerPID: 10,
            ownerName: "控制中心",
            title: "Battery",
            cgFrame: CGRect(x: 1562, y: 0, width: 76, height: 43),
            section: .visible,
            isOnScreen: true
        )
        XCTAssertEqual(battery.displayLabel, "电池")
        XCTAssertEqual(MenuBarItemInfo.suggestedSystemSymbolName(ownerName: battery.ownerName, title: battery.title), "battery.100")

        let bento = MenuBarItemInfo(
            windowID: 3,
            ownerPID: 10,
            ownerName: "控制中心",
            title: "BentoBox",
            cgFrame: CGRect(x: 1638, y: 0, width: 34, height: 43),
            section: .visible,
            isOnScreen: true
        )
        XCTAssertEqual(bento.displayLabel, "控制中心")
        XCTAssertEqual(MenuBarItemInfo.suggestedSystemSymbolName(ownerName: bento.ownerName, title: bento.title), "switch.2")
        XCTAssertTrue(SectionLayoutEngine.isLikelySystemPinnedItem(ownerName: bento.ownerName, title: bento.title, cgFrame: bento.cgFrame, screenMaxX: 1800))

        let inputMethod = MenuBarItemInfo(
            windowID: 4,
            ownerPID: 20,
            ownerName: "TextInputMenuAgent",
            title: "",
            cgFrame: CGRect(x: 1100, y: 0, width: 44, height: 43),
            section: .hidden,
            isOnScreen: false
        )
        XCTAssertEqual(inputMethod.displayLabel, "输入法")
        XCTAssertEqual(MenuBarItemInfo.suggestedSystemSymbolName(ownerName: inputMethod.ownerName, title: inputMethod.title), "keyboard")

        let thirdParty = MenuBarItemInfo(
            windowID: 5,
            ownerPID: 30,
            ownerName: "微信",
            title: "",
            cgFrame: CGRect(x: 1488, y: 0, width: 38, height: 43),
            section: .visible,
            isOnScreen: true
        )
        XCTAssertEqual(thirdParty.displayLabel, "微信")
        XCTAssertNil(MenuBarItemInfo.suggestedSystemSymbolName(ownerName: thirdParty.ownerName, title: thirdParty.title))
    }

    func testArePreferredPositionsOrderedValidatesRightToLeftInvariant() {
        // 合法位序：0 (toggle) < 1 (hidden) < 120 (always)
        XCTAssertTrue(SectionLayoutEngine.arePreferredPositionsOrdered(
            togglePos: 0,
            hiddenPos: 1,
            alwaysPos: nil
        ))
        XCTAssertTrue(SectionLayoutEngine.arePreferredPositionsOrdered(
            togglePos: 450,
            hiddenPos: 490,
            alwaysPos: 610
        ))

        // 真实故障现场：hidden=456 < toggle=488（hidden 跑到 toggle 右侧）
        XCTAssertFalse(SectionLayoutEngine.arePreferredPositionsOrdered(
            togglePos: 488,
            hiddenPos: 456,
            alwaysPos: 610
        ))

        // 缺失或越界污染值
        XCTAssertFalse(SectionLayoutEngine.arePreferredPositionsOrdered(
            togglePos: nil,
            hiddenPos: 1,
            alwaysPos: nil
        ))
        XCTAssertFalse(SectionLayoutEngine.arePreferredPositionsOrdered(
            togglePos: 3200,
            hiddenPos: 3300,
            alwaysPos: nil
        ))
        XCTAssertFalse(SectionLayoutEngine.arePreferredPositionsOrdered(
            togglePos: 10,
            hiddenPos: 30,
            alwaysPos: 20
        ))
    }

    func testChooseTempShowAnchorAndExtendedPinnedItems() {
        let toggle = CGRect(x: 1280, y: 0, width: 40, height: 43)
        let visibleItems: [RawStatusWindow] = [
            RawStatusWindow(windowID: 101, ownerPID: 10, ownerName: "NearNotch", title: "", cgFrame: CGRect(x: 1030, y: 0, width: 28, height: 43), isOnScreen: true),
            RawStatusWindow(windowID: 102, ownerPID: 11, ownerName: "QuickSnap", title: "", cgFrame: CGRect(x: 1340, y: 0, width: 32, height: 43), isOnScreen: true),
            RawStatusWindow(windowID: 103, ownerPID: 12, ownerName: "WeChat", title: "", cgFrame: CGRect(x: 1400, y: 0, width: 40, height: 43), isOnScreen: true)
        ]

        // NearNotch (1030 - 30 = 1000 < 1025) 被跳过，选中最左可用锚点 toggle (1280)
        let anchor = SectionLayoutEngine.chooseTempShowAnchor(
            visibleItems: visibleItems,
            toggleCGFrame: toggle,
            toggleWindowID: 999,
            itemWidth: 30,
            minSafeX: 1025
        )
        XCTAssertEqual(anchor, 999)

        // 当刘海/应用菜单边界推到 1320 时，toggle (1280) 也被跳过，落到 QuickSnap (1340 - 30 = 1310 < 1320? 跳过) -> WeChat (1400)
        let tightAnchor = SectionLayoutEngine.chooseTempShowAnchor(
            visibleItems: visibleItems,
            toggleCGFrame: toggle,
            toggleWindowID: 999,
            itemWidth: 30,
            minSafeX: 1320
        )
        XCTAssertEqual(tightAnchor, 103)

        // 无足够空间时返回 nil（触发降级整段显露）
        XCTAssertNil(
            SectionLayoutEngine.chooseTempShowAnchor(
                visibleItems: visibleItems,
                toggleCGFrame: toggle,
                toggleWindowID: 999,
                itemWidth: 30,
                minSafeX: 1390
            )
        )

        // Siri 与音视频录制模块不可隐藏
        XCTAssertTrue(SectionLayoutEngine.isLikelySystemPinnedItem(
            ownerName: "Siri",
            title: "Siri",
            cgFrame: CGRect(x: 1700, y: 0, width: 28, height: 43),
            screenMaxX: 1800
        ))
        XCTAssertTrue(SectionLayoutEngine.isLikelySystemPinnedItem(
            ownerName: "ControlCenter",
            title: "AudioVideoModule",
            cgFrame: CGRect(x: 1500, y: 0, width: 28, height: 43),
            screenMaxX: 1800
        ))
    }
}
