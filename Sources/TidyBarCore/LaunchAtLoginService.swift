/**
 * [INPUT]: 依赖 Foundation 与 ServiceManagement（SMAppService）
 * [OUTPUT]: 提供 LaunchAtLoginService 登录项开关读写接口
 * [POS]: TidyBarCore 的开机自启系统服务封装，供偏好设置与菜单栏配置调用
 * [PROTOCOL]: Update this header on change, then check GEMINI.md
 */

import Foundation
import ServiceManagement

// ============================================================================
// MARK: - 登录项开机自启
// ============================================================================

public enum LaunchAtLoginService {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    public static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
