# Sources/TidyBar/
> L2 | Parent: ../../GEMINI.md

Member list
main.swift: 应用入口，在 MainActor 隔离下配置 accessory 策略并挂载 AppDelegate
AppDelegate.swift: 单实例防重、核心服务装配、图标管理与保存布局动作注入、首次启动引导与退出/关机前快照并复位分割线
StatusItemDefaults.swift: 管理 NSStatusItem Preferred Position / Visible 的启动前位序自愈（保留有效主分界位序）、原子重置与移除保护
StatusItemArt.swift: CoreGraphics 矢量模板图标生成器，渲染主开关与双样式分割线
MenuBarScanner.swift: 纯同步 CGWindowList 扫描当前屏幕菜单栏图标，解析 bundleIdentifier、应用彩色图标与系统模块 SF Symbol，零录屏弹窗
MenuBarEventTap.swift: 公共 CoreGraphics CGEventTap 封装与安全超时取消，支撑跨进程事件同步
MenuBarItemMover.swift: 复刻 Ice 架构的 0x33 WindowID 双 EventTap scrombleEvent 移动引擎与 sessionEventTap 确认点击引擎
ClickForwarder.swift: 单图标临时借位 tempShow + 弹窗关闭后静默归位引擎（空间不足时安全降级整段显露）
SectionReconciler.swift: 分区记忆持久归位器，开机两段式归位 + 基于 NSWorkspace 启动通知的事件驱动单应用自动纠偏
MenuBarContextMenuBuilder.swift: 构建主按钮右键上下文菜单（防自锁警告、记住布局、校准分割线与模式切换）
SecondaryBarPanelController.swift: 纯 AppKit 圆角蒙版毛玻璃二级下拉栏面板（悬停保活、空态引导、关闭即释放）
MenuBarController.swift: NSStatusItem 三段式控制器、启动位序自愈与无条件清图撑开隐藏、防自锁原子重建、重启自动归位协调、单图标借位二级栏与右键菜单
SettingsWindowController.swift: 按需懒加载 SwiftUI 偏好设置窗（首屏可视化图标管理与记住布局、通用、外观、快捷键录制、权限引导）

[PROTOCOL]: Update this header on change, then check GEMINI.md
