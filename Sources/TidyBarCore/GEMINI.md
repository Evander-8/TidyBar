# Sources/TidyBarCore/
> L2 | Parent: ../../GEMINI.md

Member list
Models.swift: 核心配置模型、枚举、图标移动结果（MenuBarMoveResult）、快捷键组合、系统菜单栏项中文化与图标映射及窗口实体
SettingsStore.swift: 基于 UserDefaults 的 JSON 配置读写、默认值重置、监听注册/注销与变更广播
SectionLayoutEngine.swift: 防自锁顺序校验、按 WindowID 识别自身窗口与出屏检测、多屏 Y 轴带分区归类、目标落点计算、漂移检测、二级栏定位与刘海遮挡判定
HotkeyManager.swift: 基于 Carbon RegisterEventHotKey 的全局快捷键注册、暂停与事件分发
LaunchAtLoginService.swift: 基于 SMAppService.mainApp 的登录项开机自启读写接口
PermissionManager.swift: 屏幕录制与辅助功能权限检测、主动请求与系统设置深链跳转

[PROTOCOL]: Update this header on change, then check GEMINI.md
