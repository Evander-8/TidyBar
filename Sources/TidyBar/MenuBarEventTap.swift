/**
 * [INPUT]: 依赖 CoreGraphics 与 Foundation
 * [OUTPUT]: 提供 MenuBarEventTap（封装 CGEventTapCreate / CGEventTapCreateForPid 与安全超时取消，用于跨进程事件同步）
 * [POS]: TidyBar 的底层 CGEventTap 封装，支撑 MenuBarItemMover 的双 Tap 跨进程菜单栏重排与点击确认
 * [PROTOCOL]: Update this header on change, then check GEMINI.md
 */

import CoreGraphics
import Foundation

// ============================================================================
// MARK: - CGEventTap 封装（纯公共 CoreGraphics API）
// ============================================================================

@MainActor
final class MenuBarEventTap {
    enum Location {
        case hidEventTap
        case sessionEventTap
        case annotatedSessionEventTap
        case pid(pid_t)
    }

    @MainActor
    struct Proxy {
        private let tap: MenuBarEventTap

        var label: String { tap.label }
        var isEnabled: Bool { tap.isEnabled }

        fileprivate init(tap: MenuBarEventTap) {
            self.tap = tap
        }

        func enable() {
            tap.enable()
        }

        func disable() {
            tap.disable()
        }
    }

    let label: String

    private let runLoop: CFRunLoop = CFRunLoopGetMain()
    private let mode: CFRunLoopMode = .commonModes
    private nonisolated let callback: (MenuBarEventTap, CGEventTapProxy, CGEventType, CGEvent) -> Unmanaged<CGEvent>?

    private var machPort: CFMachPort?
    private var source: CFRunLoopSource?
    private var timeoutTask: Task<Void, Never>?

    var hasValidPort: Bool {
        machPort != nil && source != nil
    }

    var isEnabled: Bool {
        guard let machPort else { return false }
        return CGEvent.tapIsEnabled(tap: machPort)
    }

    init(
        label: String,
        options: CGEventTapOptions,
        location: Location,
        place: CGEventTapPlacement,
        types: [CGEventType],
        callback: @escaping @MainActor (_ proxy: Proxy, _ type: CGEventType, _ event: CGEvent) -> CGEvent?
    ) {
        self.label = label
        self.callback = { @MainActor tap, _, type, event in
            callback(Proxy(tap: tap), type, event).map(Unmanaged.passUnretained)
        }

        let mask = types.reduce(into: CGEventMask(0)) { partial, eventType in
            partial |= (1 << eventType.rawValue)
        }

        guard let createdPort = Self.createTapMachPort(
            location: location,
            place: place,
            options: options,
            eventsOfInterest: mask,
            callback: menuBarEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }

        guard let createdSource = CFMachPortCreateRunLoopSource(nil, createdPort, 0) else {
            CFMachPortInvalidate(createdPort)
            return
        }

        self.machPort = createdPort
        self.source = createdSource
    }

    deinit {
        timeoutTask?.cancel()
        if let source {
            CFRunLoopRemoveSource(runLoop, source, mode)
        }
        if let machPort {
            CGEvent.tapEnable(tap: machPort, enable: false)
            CFMachPortInvalidate(machPort)
        }
    }

    func enable() {
        guard let source, let machPort else { return }
        CFRunLoopAddSource(runLoop, source, mode)
        CGEvent.tapEnable(tap: machPort, enable: true)
    }

    func enable(timeout: Duration, onTimeout: @escaping @MainActor () -> Void) {
        timeoutTask?.cancel()
        enable()
        timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard let self, self.isEnabled else { return }
            onTimeout()
        }
    }

    func disable() {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let source {
            CFRunLoopRemoveSource(runLoop, source, mode)
        }
        if let machPort {
            CGEvent.tapEnable(tap: machPort, enable: false)
        }
    }

    fileprivate nonisolated static func performCallback(
        for eventTap: MenuBarEventTap,
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        eventTap.callback(eventTap, proxy, type, event)
    }

    private static func createTapMachPort(
        location: Location,
        place: CGEventTapPlacement,
        options: CGEventTapOptions,
        eventsOfInterest: CGEventMask,
        callback: CGEventTapCallBack,
        userInfo: UnsafeMutableRawPointer?
    ) -> CFMachPort? {
        switch location {
        case .pid(let pid):
            return CGEvent.tapCreateForPid(
                pid: pid,
                place: place,
                options: options,
                eventsOfInterest: eventsOfInterest,
                callback: callback,
                userInfo: userInfo
            )
        case .hidEventTap:
            return CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: place,
                options: options,
                eventsOfInterest: eventsOfInterest,
                callback: callback,
                userInfo: userInfo
            )
        case .sessionEventTap:
            return CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: place,
                options: options,
                eventsOfInterest: eventsOfInterest,
                callback: callback,
                userInfo: userInfo
            )
        case .annotatedSessionEventTap:
            return CGEvent.tapCreate(
                tap: .cgAnnotatedSessionEventTap,
                place: place,
                options: options,
                eventsOfInterest: eventsOfInterest,
                callback: callback,
                userInfo: userInfo
            )
        }
    }
}

private func menuBarEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }
    let eventTap = Unmanaged<MenuBarEventTap>.fromOpaque(refcon).takeUnretainedValue()
    return MenuBarEventTap.performCallback(for: eventTap, proxy: proxy, type: type, event: event)
}
