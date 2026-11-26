/**
 * [INPUT]: 依赖 AppKit、CoreGraphics、MenuBarEventTap 与 TidyBarCore（MenuBarItemInfo、MenuBarSection、MenuBarMoveResult、SectionLayoutEngine、PermissionManager）
 * [OUTPUT]: 提供 MenuBarItemMover（复刻 Ice 的 0x33 WindowID 双 EventTap scrombleEvent 移动引擎与 sessionEventTap 确认点击引擎）
 * [POS]: TidyBar 的菜单栏跨进程事件底层引擎，支持折叠态无闪现静默移动、点击与分割线纠偏
 * [PROTOCOL]: Update this header on change, then check GEMINI.md
 */

import AppKit
import CoreGraphics
import Foundation
import TidyBarCore

// ============================================================================
// MARK: - 私有 EventField（与 Ice / macOS WindowServer 一致）
// ============================================================================

private extension CGEventField {
    /// macOS WindowServer 用于将鼠标事件直接绑定到指定菜单栏窗口的内部字段（0x33 = 51）
    static let tidyWindowID = CGEventField(rawValue: 0x33)!
}

// ============================================================================
// MARK: - 菜单栏图标移动与点击引擎
// ============================================================================

@MainActor
enum MenuBarItemMover {
    enum MoveDestination: Equatable {
        case leftOfItem(CGWindowID)
        case rightOfItem(CGWindowID)

        var targetWindowID: CGWindowID {
            switch self {
            case .leftOfItem(let id), .rightOfItem(let id): return id
            }
        }
    }

    // MARK: - Fast Window Frame Query

    static func windowFrame(for windowID: CGWindowID) -> CGRect? {
        var pointer = UnsafeRawPointer(bitPattern: Int(windowID))
        guard let array = CFArrayCreate(kCFAllocatorDefault, &pointer, 1, nil),
              let list = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]],
              let first = list.first,
              let boundsDict = first[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
            return nil
        }
        return rect
    }

    // MARK: - Core Move & Click Primitives (Ice Architecture)

    /// 跨进程移动指定菜单栏图标至目标窗口左/右侧（在折叠态也可静默完成，无需先展开全部分割线）
    static func moveItem(
        windowID: CGWindowID,
        ownerPID: pid_t,
        to destination: MoveDestination
    ) async -> Bool {
        guard PermissionManager.hasAccessibilityPermission else { return false }
        guard let initialFrame = windowFrame(for: windowID) else { return false }

        // 先检查是否已紧贴目标位置
        if let targetFrame = windowFrame(for: destination.targetWindowID) {
            switch destination {
            case .leftOfItem where abs(initialFrame.maxX - targetFrame.minX) <= 1.0:
                return true
            case .rightOfItem where abs(initialFrame.minX - targetFrame.maxX) <= 1.0:
                return true
            default:
                break
            }
        }

        let originalCursor = CGEvent(source: nil)?.location
        CGDisplayHideCursor(CGMainDisplayID())
        defer {
            if let originalCursor {
                CGWarpMouseCursorPosition(originalCursor)
            }
            CGDisplayShowCursor(CGMainDisplayID())
        }

        for attempt in 0..<3 {
            guard let endPoint = computeEndPoint(for: destination),
                  let currentFrame = windowFrame(for: windowID) else {
                return false
            }

            let source = CGEventSource(stateID: .hidSystemState)
            permitAllEvents()

            let startPoint = CGPoint(x: 20_000, y: 20_000)
            let fallbackPoint = CGPoint(x: currentFrame.midX, y: currentFrame.midY)

            guard let downEvent = makeMenuBarEvent(
                type: .leftMouseDown,
                location: startPoint,
                windowID: windowID,
                ownerPID: ownerPID,
                flags: .maskCommand,
                clickState: nil,
                source: source
            ),
                  let upEvent = makeMenuBarEvent(
                    type: .leftMouseUp,
                    location: endPoint,
                    windowID: destination.targetWindowID,
                    ownerPID: ownerPID,
                    flags: [],
                    clickState: nil,
                    source: source
                  ),
                  let fallbackEvent = makeMenuBarEvent(
                    type: .leftMouseUp,
                    location: fallbackPoint,
                    windowID: windowID,
                    ownerPID: ownerPID,
                    flags: [],
                    clickState: nil,
                    source: source
                  ) else {
                return false
            }

            let downOK = await scrombleEvent(
                downEvent,
                ownerPID: ownerPID,
                observedWindowID: windowID,
                waitForFrameChange: true
            )
            var upOK = false
            if downOK {
                upOK = await scrombleEvent(
                    upEvent,
                    ownerPID: ownerPID,
                    observedWindowID: windowID,
                    waitForFrameChange: true
                )
            }

            if !downOK || !upOK {
                _ = await postEventAndWaitToReceive(fallbackEvent, to: .sessionEventTap, timeout: .milliseconds(50))
            }

            try? await Task.sleep(for: .milliseconds(35))
            if let updatedFrame = windowFrame(for: windowID), updatedFrame != initialFrame {
                return true
            }

            if attempt < 2 {
                await wakeUpItem(windowID: windowID, ownerPID: ownerPID)
                try? await Task.sleep(for: .milliseconds(25))
            }
        }

        return false
    }

    /// 向指定菜单栏图标发送经过 EventTap 确认的纯净鼠标左/右键点击
    static func clickItem(
        windowID: CGWindowID,
        ownerPID: pid_t,
        at point: CGPoint,
        mouseButton: CGMouseButton
    ) async -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        permitAllEvents()

        let originalCursor = CGEvent(source: nil)?.location
        CGDisplayHideCursor(CGMainDisplayID())
        defer {
            if let originalCursor {
                CGWarpMouseCursorPosition(originalCursor)
            }
            CGDisplayShowCursor(CGMainDisplayID())
        }

        let downType: CGEventType = mouseButton == .right ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = mouseButton == .right ? .rightMouseUp : .leftMouseUp

        guard let downEvent = makeMenuBarEvent(
            type: downType,
            location: point,
            windowID: windowID,
            ownerPID: ownerPID,
            flags: [],
            clickState: 1,
            source: source
        ),
              let upEvent = makeMenuBarEvent(
                type: upType,
                location: point,
                windowID: windowID,
                ownerPID: ownerPID,
                flags: [],
                clickState: 1,
                source: source
              ) else {
            return false
        }

        CGWarpMouseCursorPosition(point)
        let downReceived = await postEventAndWaitToReceive(downEvent, to: .sessionEventTap, timeout: .milliseconds(60))
        try? await Task.sleep(for: .milliseconds(25))
        let upReceived = await postEventAndWaitToReceive(upEvent, to: .sessionEventTap, timeout: .milliseconds(60))

        if downReceived && !upReceived {
            upEvent.post(tap: .cgSessionEventTap)
        }
        return downReceived
    }

    /// 当普通/总是隐藏分割线顺序错位且均在屏幕内时，直接通过程序化拖拽修正顺序
    static func enforceDividerOrder(
        toggleWindowID: CGWindowID,
        hiddenWindowID: CGWindowID,
        alwaysWindowID: CGWindowID?,
        ownPID: pid_t
    ) async -> Bool {
        guard let toggleFrame = windowFrame(for: toggleWindowID),
              let hiddenFrame = windowFrame(for: hiddenWindowID) else {
            return false
        }

        var ok = true
        if hiddenFrame.maxX > toggleFrame.minX + 2 {
            let movedHidden = await moveItem(
                windowID: hiddenWindowID,
                ownerPID: ownPID,
                to: .leftOfItem(toggleWindowID)
            )
            ok = ok && movedHidden
        }

        if let alwaysID = alwaysWindowID,
           let latestHidden = windowFrame(for: hiddenWindowID),
           let alwaysFrame = windowFrame(for: alwaysID),
           alwaysFrame.maxX > latestHidden.minX + 2 {
            let movedAlways = await moveItem(
                windowID: alwaysID,
                ownerPID: ownPID,
                to: .leftOfItem(hiddenWindowID)
            )
            ok = ok && movedAlways
        }

        return ok
    }

    // MARK: - Settings Icon Manager Operations

    /// 将指定菜单栏图标移入目标分区：优先折叠态静默移动，若未落位则展开分割线后重试一次
    static func move(
        item: MenuBarItemInfo,
        to targetSection: MenuBarSection,
        menuBarCGMinY: CGFloat,
        prepareDividers: @escaping () -> Void,
        readDividerSnapshots: @escaping () -> (toggle: RawStatusWindow, hidden: RawStatusWindow, always: RawStatusWindow?)?
    ) async -> MenuBarMoveResult {
        guard PermissionManager.hasAccessibilityPermission else {
            return .missingAccessibilityPermission
        }

        for attempt in 0..<2 {
            if attempt == 1 {
                prepareDividers()
                try? await Task.sleep(for: .milliseconds(70))
            }

            guard let dividers = readDividerSnapshots() else {
                return .failed("无法读取菜单栏分割线位置")
            }

            let order = SectionLayoutEngine.validateDividerOrder(
                toggleFrame: dividers.toggle.cgFrame,
                hiddenDividerFrame: dividers.hidden.cgFrame,
                alwaysHiddenDividerFrame: dividers.always?.cgFrame
            )
            guard order == .valid else {
                return .dividerOrderInvalid
            }

            guard let currentFrame = currentCGFrame(for: item.windowID, menuBarCGMinY: menuBarCGMinY) else {
                return .failed("目标图标已不在当前屏幕菜单栏中")
            }

            if isInSection(
                midX: currentFrame.midX,
                section: targetSection,
                hiddenRightX: dividers.hidden.cgFrame.maxX,
                alwaysRightX: dividers.always?.cgFrame.maxX
            ) {
                return .moved
            }

            let destination: MoveDestination
            switch targetSection {
            case .visible:
                destination = .rightOfItem(dividers.toggle.windowID)
            case .hidden:
                destination = .leftOfItem(dividers.hidden.windowID)
            case .alwaysHidden:
                let anchor = dividers.always?.windowID ?? dividers.hidden.windowID
                destination = .leftOfItem(anchor)
            }

            let moved = await moveItem(
                windowID: item.windowID,
                ownerPID: item.ownerPID,
                to: destination
            )
            try? await Task.sleep(for: .milliseconds(60))

            if let updatedDividers = readDividerSnapshots(),
               let afterFrame = currentCGFrame(for: item.windowID, menuBarCGMinY: menuBarCGMinY),
               isInSection(
                midX: afterFrame.midX,
                section: targetSection,
                hiddenRightX: updatedDividers.hidden.cgFrame.maxX,
                alwaysRightX: updatedDividers.always?.cgFrame.maxX
               ) {
                return .moved
            }

            if attempt == 1 {
                if !moved, let afterFrame = currentCGFrame(for: item.windowID, menuBarCGMinY: menuBarCGMinY),
                   abs(afterFrame.midX - currentFrame.midX) < 4 {
                    return .immovableSystemItem
                }
                return .failed("未能移动到目标分区，可手动按住 ⌘ 拖入分隔线左侧")
            }
        }

        return .failed("未能完成图标移动")
    }

    /// 将漂移的「|」分割线移回 TidyBar 主开关紧邻左侧，把夹在中间的图标直接收入隐藏区
    static func alignHiddenDividerNextToToggle(
        menuBarCGMinY: CGFloat,
        prepareDividers: @escaping () -> Void,
        readDividerSnapshots: @escaping () -> (toggle: RawStatusWindow, hidden: RawStatusWindow, always: RawStatusWindow?)?
    ) async -> MenuBarMoveResult {
        guard PermissionManager.hasAccessibilityPermission else {
            return .missingAccessibilityPermission
        }

        prepareDividers()
        try? await Task.sleep(for: .milliseconds(65))

        guard let dividers = readDividerSnapshots() else {
            return .failed("无法读取菜单栏分割线位置")
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ok = await moveItem(
            windowID: dividers.hidden.windowID,
            ownerPID: ownPID,
            to: .leftOfItem(dividers.toggle.windowID)
        )
        try? await Task.sleep(for: .milliseconds(60))

        guard let updated = readDividerSnapshots() else {
            return .failed("校准后读取位置失败")
        }
        let between = SectionLayoutEngine.itemsBetweenHiddenDividerAndToggle(
            MenuBarScanner.readRawStatusWindows(),
            toggleCGFrame: updated.toggle.cgFrame,
            hiddenDividerCGFrame: updated.hidden.cgFrame,
            menuBarCGMinY: menuBarCGMinY,
            ownPID: ownPID
        )
        return (ok && between.isEmpty) ? .moved : .failed("仍有图标位于分割线与主开关之间，请再试一次")
    }

    // MARK: - Private Dual-Tap & Event Helpers

    private static func computeEndPoint(for destination: MoveDestination) -> CGPoint? {
        guard let targetFrame = windowFrame(for: destination.targetWindowID) else {
            return nil
        }
        switch destination {
        case .leftOfItem:
            return CGPoint(x: targetFrame.minX, y: targetFrame.midY)
        case .rightOfItem:
            return CGPoint(x: targetFrame.maxX, y: targetFrame.midY)
        }
    }

    private static func permitAllEvents() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let mask: CGEventFilterMask = [
            .permitLocalMouseEvents,
            .permitLocalKeyboardEvents,
            .permitSystemDefinedEvents
        ]
        source.setLocalEventsFilterDuringSuppressionState(mask, state: .eventSuppressionStateRemoteMouseDrag)
        source.setLocalEventsFilterDuringSuppressionState(mask, state: .eventSuppressionStateSuppressionInterval)
        source.localEventsSuppressionInterval = 0
    }

    private static func wakeUpItem(windowID: CGWindowID, ownerPID: pid_t) async {
        guard let frame = windowFrame(for: windowID),
              let source = CGEventSource(stateID: .hidSystemState) else { return }
        let center = CGPoint(x: frame.midX, y: frame.midY)

        // 使用 .maskCommand 的 mouseDown + 无修饰 mouseUp 唤醒目标窗口响应而不弹开其菜单
        if let down = makeMenuBarEvent(
            type: .leftMouseDown,
            location: center,
            windowID: windowID,
            ownerPID: ownerPID,
            flags: .maskCommand,
            clickState: nil,
            source: source
        ) {
            _ = await scrombleEvent(down, ownerPID: ownerPID, observedWindowID: windowID, waitForFrameChange: false)
        }
        if let up = makeMenuBarEvent(
            type: .leftMouseUp,
            location: center,
            windowID: windowID,
            ownerPID: ownerPID,
            flags: [],
            clickState: nil,
            source: source
        ) {
            _ = await scrombleEvent(up, ownerPID: ownerPID, observedWindowID: windowID, waitForFrameChange: false)
        }
    }

    private static func postEventAndWaitToReceive(
        _ event: CGEvent,
        to location: MenuBarEventTap.Location,
        timeout: Duration
    ) async -> Bool {
        var tapRef: MenuBarEventTap?
        var hasResumed = false

        let received = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let tap = MenuBarEventTap(
                label: "postWait",
                options: .listenOnly,
                location: location,
                place: .tailAppendEventTap,
                types: [event.type]
            ) { proxy, type, rEvent in
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                    proxy.enable()
                    return nil
                }
                guard eventsMatch(rEvent, event) else { return nil }
                guard !hasResumed else { return nil }
                hasResumed = true
                proxy.disable()
                continuation.resume(returning: true)
                return nil
            }
            tapRef = tap

            guard tap.hasValidPort else {
                hasResumed = true
                continuation.resume(returning: false)
                return
            }

            tap.enable(timeout: timeout) {
                guard !hasResumed else { return }
                hasResumed = true
                tapRef?.disable()
                continuation.resume(returning: false)
            }

            postEvent(event, to: location)
        }
        return received
    }

    private static func scrombleEvent(
        _ event: CGEvent,
        ownerPID: pid_t,
        observedWindowID: CGWindowID,
        waitForFrameChange: Bool
    ) async -> Bool {
        let initialFrame = waitForFrameChange ? windowFrame(for: observedWindowID) : nil

        guard let nullEvent = CGEvent(source: nil) else { return false }
        let nullUserData = Int64(truncatingIfNeeded: Int(bitPattern: ObjectIdentifier(nullEvent)))
        nullEvent.setIntegerValueField(.eventSourceUserData, value: nullUserData)

        let delivered = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var hasResumed = false
            var tap1Ref: MenuBarEventTap?
            var tap2Ref: MenuBarEventTap?

            let tap1 = MenuBarEventTap(
                label: "scromble1",
                options: .defaultTap,
                location: .pid(ownerPID),
                place: .tailAppendEventTap,
                types: [nullEvent.type]
            ) { proxy, type, rEvent in
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                    proxy.enable()
                    return nil
                }
                guard rEvent.getIntegerValueField(.eventSourceUserData) == nullUserData else {
                    return nil
                }
                proxy.disable()
                postEvent(event, to: .sessionEventTap)
                return nil
            }

            let tap2 = MenuBarEventTap(
                label: "scromble2",
                options: .listenOnly,
                location: .sessionEventTap,
                place: .tailAppendEventTap,
                types: [event.type]
            ) { proxy, type, rEvent in
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                    proxy.enable()
                    return nil
                }
                guard eventsMatch(rEvent, event) else { return nil }
                guard !hasResumed else { return nil }
                hasResumed = true
                proxy.disable()
                tap1Ref?.disable()
                postEvent(event, to: .pid(ownerPID))
                continuation.resume(returning: true)
                return nil
            }

            tap1Ref = tap1
            tap2Ref = tap2

            guard tap1.hasValidPort && tap2.hasValidPort else {
                hasResumed = true
                tap1.disable()
                tap2.disable()
                continuation.resume(returning: false)
                return
            }

            tap1.enable()
            tap2.enable(timeout: .milliseconds(80)) {
                guard !hasResumed else { return }
                hasResumed = true
                tap1Ref?.disable()
                tap2Ref?.disable()
                continuation.resume(returning: false)
            }

            postEvent(nullEvent, to: .pid(ownerPID))
        }

        guard delivered else { return false }
        guard waitForFrameChange else { return true }

        guard let initialFrame else {
            try? await Task.sleep(for: .milliseconds(50))
            return true
        }

        return await waitForWindowFrameChange(
            windowID: observedWindowID,
            initialFrame: initialFrame,
            timeoutMs: 140
        )
    }

    private static func waitForWindowFrameChange(
        windowID: CGWindowID,
        initialFrame: CGRect,
        timeoutMs: Int
    ) async -> Bool {
        let attempts = max(1, timeoutMs / 4)
        for _ in 0..<attempts {
            guard let current = windowFrame(for: windowID) else { return false }
            if current != initialFrame {
                return true
            }
            try? await Task.sleep(for: .milliseconds(4))
        }
        return false
    }

    private static func postEvent(_ event: CGEvent, to location: MenuBarEventTap.Location) {
        switch location {
        case .hidEventTap:
            event.post(tap: .cghidEventTap)
        case .sessionEventTap:
            event.post(tap: .cgSessionEventTap)
        case .annotatedSessionEventTap:
            event.post(tap: .cgAnnotatedSessionEventTap)
        case .pid(let pid):
            event.postToPid(pid)
        }
    }

    private static func makeMenuBarEvent(
        type: CGEventType,
        location: CGPoint,
        windowID: CGWindowID,
        ownerPID: pid_t,
        flags: CGEventFlags,
        clickState: Int64?,
        source: CGEventSource?
    ) -> CGEvent? {
        let button: CGMouseButton = (type == .rightMouseDown || type == .rightMouseUp) ? .right : .left
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: button
        ) else {
            return nil
        }

        event.flags = flags

        let userData = Int64(truncatingIfNeeded: Int(bitPattern: ObjectIdentifier(event)))
        let winID = Int64(windowID)

        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(ownerPID))
        event.setIntegerValueField(.eventSourceUserData, value: userData)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: winID)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: winID)
        event.setIntegerValueField(.tidyWindowID, value: winID)

        if let clickState {
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
        }
        return event
    }

    private static func eventsMatch(_ lhs: CGEvent, _ rhs: CGEvent) -> Bool {
        let fields: [CGEventField] = [
            .eventSourceUserData,
            .mouseEventWindowUnderMousePointer,
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
            .tidyWindowID
        ]
        return fields.allSatisfy { field in
            lhs.getIntegerValueField(field) == rhs.getIntegerValueField(field)
        }
    }

    private static func isInSection(
        midX: CGFloat,
        section: MenuBarSection,
        hiddenRightX: CGFloat,
        alwaysRightX: CGFloat?
    ) -> Bool {
        switch section {
        case .alwaysHidden:
            guard let alwaysRightX else { return false }
            return midX <= alwaysRightX
        case .hidden:
            if let alwaysRightX, midX <= alwaysRightX {
                return false
            }
            return midX <= hiddenRightX
        case .visible:
            return midX > hiddenRightX
        }
    }

    private static func currentCGFrame(for windowID: CGWindowID, menuBarCGMinY: CGFloat) -> CGRect? {
        guard let frame = windowFrame(for: windowID),
              abs(frame.minY - menuBarCGMinY) <= 10 else {
            return nil
        }
        return frame
    }
}
