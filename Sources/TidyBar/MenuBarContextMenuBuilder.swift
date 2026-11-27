/**
 * [INPUT]: 依赖 AppKit 与 TidyBarCore（DisplayMode、AutoRehideDelay、DividerOrderValidation、TidyBarSettings）
 * [OUTPUT]: 提供 MenuBarContextMenuBuilder（构建主按钮右键上下文菜单，含防自锁警告、校准分割线、一键记住布局与模式/自收起切换）
 * [POS]: TidyBar 的右键菜单装配器，从 MenuBarController 抽离界面构建细节，保持主控制器精简可读
 * [PROTOCOL]: Update this header on change, then check GEMINI.md
 */

import AppKit
import TidyBarCore

// ============================================================================
// MARK: - 主按钮右键菜单构建器
// ============================================================================

@MainActor
enum MenuBarContextMenuBuilder {
    struct Actions {
        let manageIcons: Selector
        let saveCurrentLayout: Selector
        let alignDivider: Selector
        let toggleHidden: Selector
        let showAll: Selector
        let selectDisplayMode: Selector
        let selectRehideDelay: Selector
        let toggleAlwaysHiddenSection: Selector
        let openSettings: Selector
        let quit: Selector
    }

    static func build(
        target: AnyObject,
        actions: Actions,
        settings: TidyBarSettings,
        isCollapsed: Bool,
        lastOrderIssue: DividerOrderValidation,
        driftedBetweenCount: Int
    ) -> NSMenu {
        let menu = NSMenu()

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

        let manageItem = NSMenuItem(title: "管理隐藏图标…", action: actions.manageIcons, keyEquivalent: "")
        manageItem.target = target
        menu.addItem(manageItem)

        let pinnedCount = settings.pinnedSections.count
        let saveTitle = pinnedCount > 0 ? "记住当前布局（已记 \(pinnedCount) 项）" : "记住当前图标布局"
        let saveItem = NSMenuItem(title: saveTitle, action: actions.saveCurrentLayout, keyEquivalent: "")
        saveItem.target = target
        menu.addItem(saveItem)

        if driftedBetweenCount > 0 {
            let alignItem = NSMenuItem(
                title: "校准分割线（隐藏中间 \(driftedBetweenCount) 个图标）",
                action: actions.alignDivider,
                keyEquivalent: ""
            )
            alignItem.target = target
            menu.addItem(alignItem)
        }

        menu.addItem(.separator())

        let toggleTitle = isCollapsed
            ? "展开隐藏区 (\(settings.toggleHotkey.displayString))"
            : "收起隐藏区 (\(settings.toggleHotkey.displayString))"
        let toggleMenuItem = NSMenuItem(title: toggleTitle, action: actions.toggleHidden, keyEquivalent: "")
        toggleMenuItem.target = target
        menu.addItem(toggleMenuItem)

        if settings.enableAlwaysHiddenSection {
            let showAllItem = NSMenuItem(title: "显示全部图标（含总是隐藏区）", action: actions.showAll, keyEquivalent: "")
            showAllItem.target = target
            menu.addItem(showAllItem)
        }

        menu.addItem(.separator())

        let modeMenu = NSMenu()
        for mode in DisplayMode.allCases {
            let item = NSMenuItem(title: mode.displayTitle, action: actions.selectDisplayMode, keyEquivalent: "")
            item.target = target
            item.representedObject = mode.rawValue
            item.state = settings.displayMode == mode ? .on : .off
            modeMenu.addItem(item)
        }
        let modeParent = NSMenuItem(title: "显示模式：\(settings.displayMode.displayTitle)", action: nil, keyEquivalent: "")
        modeParent.submenu = modeMenu
        menu.addItem(modeParent)

        let rehideMenu = NSMenu()
        for delay in AutoRehideDelay.allCases {
            let item = NSMenuItem(title: delay.displayTitle, action: actions.selectRehideDelay, keyEquivalent: "")
            item.target = target
            item.tag = delay.rawValue
            item.state = settings.autoRehideDelay == delay ? .on : .off
            rehideMenu.addItem(item)
        }
        let rehideParent = NSMenuItem(title: "自动重新收起：\(settings.autoRehideDelay.displayTitle)", action: nil, keyEquivalent: "")
        rehideParent.submenu = rehideMenu
        menu.addItem(rehideParent)

        let alwaysSectionItem = NSMenuItem(
            title: "启用「总是隐藏区」(‖)",
            action: actions.toggleAlwaysHiddenSection,
            keyEquivalent: ""
        )
        alwaysSectionItem.target = target
        alwaysSectionItem.state = settings.enableAlwaysHiddenSection ? .on : .off
        menu.addItem(alwaysSectionItem)

        menu.addItem(.separator())

        let prefsItem = NSMenuItem(title: "偏好设置…", action: actions.openSettings, keyEquivalent: ",")
        prefsItem.target = target
        menu.addItem(prefsItem)

        let quitItem = NSMenuItem(title: "退出 TidyBar", action: actions.quit, keyEquivalent: "q")
        quitItem.target = target
        menu.addItem(quitItem)

        return menu
    }
}
