# Sources/TidyBarCore/
> L2 | Parent: ../../GEMINI.md

Member list
Models.swift: 核心配置模型、枚举、图标移动结果（MenuBarMoveResult）、快捷键组合、持久化主键 stableKey 与分区记忆字典（pinnedSections）、系统菜单栏项中文化与图标映射
SettingsStore.swift: 基于 UserDefaults 的 JSON 配置读写、默认值重置、监听注册/注销与变更广播
SectionLayoutEngine.swift: Preferred Position 位序校验（兼容折叠态 10_000pt 偏移）、防自锁顺序校验、按 WindowID 识别自身窗口、三段式分区、computeDriftedItems 漂移计算、临时借位锚点计算、二级栏定位与系统固定项/刘海判定
HotkeyManager.swift: 基于 Carbon RegisterEventHotKey 的全局快捷键注册、暂停与事件分发
LaunchAtLoginService.swift: 基于 SMAppService.mainApp 的登录项开机自启读写接口
PermissionManager.swift: 屏幕录制与辅助功能权限检测、主动请求与系统设置深链跳转

[PROTOCOL]: Update this header on change, then check GEMINI.md
