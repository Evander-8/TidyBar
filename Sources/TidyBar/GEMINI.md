# Sources/TidyBar/
> L2 | Parent: ../../GEMINI.md

Member list
main.swift: 应用入口，在 MainActor 隔离下配置 accessory 策略并挂载 AppDelegate
AppDelegate.swift: 单实例防重、核心服务装配、图标管理动作注入、首次启动引导弹窗
StatusItemArt.swift: CoreGraphics 矢量模板图标生成器，渲染主开关与双样式分割线
MenuBarScanner.swift: 纯同步 CGWindowList 扫描当前屏幕菜单栏图标并解析应用彩色图标，零录屏弹窗
MenuBarItemMover.swift: 供「图标管理」页与校准分割线使用的隔离 .privateState 平滑 Command+Drag 执行器
ClickForwarder.swift: 收缩分割线显露目标、等待连续 2 帧静止且避开刘海后锁点投递纯净鼠标点击
SecondaryBarPanelController.swift: 纯 AppKit 圆角蒙版毛玻璃二级下拉栏面板（悬停保活、空态引导、关闭即释放）
MenuBarController.swift: NSStatusItem 三段式控制器、防自锁折叠、同步秒开二级栏、转发后延迟收起与右键菜单
SettingsWindowController.swift: 按需懒加载 SwiftUI 偏好设置窗（首屏可视化图标管理、通用、外观、快捷键录制、权限引导）

[PROTOCOL]: Update this header on change, then check GEMINI.md
