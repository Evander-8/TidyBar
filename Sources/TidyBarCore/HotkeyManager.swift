/**
 * [INPUT]: 依赖 Carbon.HIToolbox（RegisterEventHotKey/InstallEventHandler）与 Models.HotkeyCombo
 * [OUTPUT]: 提供 HotkeyManager 全局快捷键注册引擎（无需辅助功能权限，支持暂停、重绑与冲突返回）
 * [POS]: TidyBarCore 的全局热键管理器，将快捷键触发转发到菜单栏控制器
 * [PROTOCOL]: Update this header on change, then check GEMINI.md
 */

import Carbon
import Foundation

// ============================================================================
// MARK: - 全局热键引擎
// ============================================================================

public final class HotkeyManager {
    private static let signature: OSType = 0x54424152 // 'TBAR'
    private static let toggleHotKeyID: UInt32 = 1

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var currentCombo: HotkeyCombo?
    private var isSuspended = false

    public var onTrigger: (() -> Void)?

    public init() {
        installHandlerIfNeeded()
    }

    deinit {
        unregister()
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    @discardableResult
    public func register(combo: HotkeyCombo) -> Bool {
        currentCombo = combo
        installHandlerIfNeeded()
        unregister()

        guard !isSuspended else { return true }

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: Self.toggleHotKeyID)
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers,
            id,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let validRef = ref else {
            return false
        }
        hotKeyRef = validRef
        return true
    }

    public func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        isSuspended = suspended
        if suspended {
            unregister()
        } else if let combo = currentCombo {
            _ = register(combo: combo)
        }
    }

    public func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr,
                      hotKeyID.signature == HotkeyManager.signature,
                      hotKeyID.id == HotkeyManager.toggleHotKeyID else {
                    return noErr
                }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.onTrigger?()
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &handler
        )
        if status == noErr {
            eventHandlerRef = handler
        }
    }
}
