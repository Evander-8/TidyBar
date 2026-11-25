/**
 * [INPUT]: 依赖 AppKit、CoreGraphics 与 TidyBarCore（ToggleIconStyle、DividerStyle）
 * [OUTPUT]: 提供 StatusItemArt 矢量模板图标绘制器，渲染主开关与双样式分割线
 * [POS]: TidyBar 的状态栏视觉绘制层，确保深浅色菜单栏自动反白与 Retina 清晰度
 * [PROTOCOL]: Update this header on change, then check GEMINI.md
 */

import AppKit
import CoreGraphics
import TidyBarCore

// ============================================================================
// MARK: - 菜单栏模板图标绘制
// ============================================================================

enum StatusItemArt {
    static func toggleImage(style: ToggleIconStyle, isExpanded: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.labelColor.setStroke()
            NSColor.labelColor.setFill()

            let cx = rect.midX
            let cy = rect.midY

            switch style {
            case .chevron:
                let path = NSBezierPath()
                path.lineWidth = 1.65
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                if isExpanded {
                    // 展开态朝右，暗示向右收拢回隐藏区
                    path.move(to: NSPoint(x: cx - 2.2, y: cy + 4.0))
                    path.line(to: NSPoint(x: cx + 2.3, y: cy))
                    path.line(to: NSPoint(x: cx - 2.2, y: cy - 4.0))
                } else {
                    // 折叠态朝左，暗示向左展开隐藏图标
                    path.move(to: NSPoint(x: cx + 2.2, y: cy + 4.0))
                    path.line(to: NSPoint(x: cx - 2.3, y: cy))
                    path.line(to: NSPoint(x: cx + 2.2, y: cy - 4.0))
                }
                path.stroke()

            case .dot:
                if isExpanded {
                    let ring = NSBezierPath(ovalIn: NSRect(x: cx - 3.6, y: cy - 3.6, width: 7.2, height: 7.2))
                    ring.lineWidth = 1.6
                    ring.stroke()
                } else {
                    let dot = NSBezierPath(ovalIn: NSRect(x: cx - 3.0, y: cy - 3.0, width: 6.0, height: 6.0))
                    dot.fill()
                }

            case .verticalBar:
                let pill = NSBezierPath(
                    roundedRect: NSRect(x: cx - 1.15, y: cy - 5.5, width: 2.3, height: 11.0),
                    xRadius: 1.15,
                    yRadius: 1.15
                )
                pill.fill()
                if isExpanded {
                    let tip = NSBezierPath(ovalIn: NSRect(x: cx + 2.6, y: cy - 1.25, width: 2.5, height: 2.5))
                    tip.fill()
                }

            case .pill:
                let rectWidth: CGFloat = isExpanded ? 11.0 : 9.0
                let capsule = NSBezierPath(
                    roundedRect: NSRect(x: cx - rectWidth / 2, y: cy - 3.0, width: rectWidth, height: 6.0),
                    xRadius: 3.0,
                    yRadius: 3.0
                )
                if isExpanded {
                    capsule.lineWidth = 1.4
                    capsule.stroke()
                } else {
                    capsule.fill()
                }
            }

            return true
        }
        image.isTemplate = true
        return image
    }

    static func dividerImage(style: DividerStyle, isAlwaysHidden: Bool) -> NSImage {
        let width: CGFloat = isAlwaysHidden ? 12 : 10
        let size = NSSize(width: width, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let color = NSColor.labelColor.withAlphaComponent(isAlwaysHidden ? 0.55 : 0.42)
            color.setFill()
            color.setStroke()

            let cx = rect.midX
            let cy = rect.midY

            switch style {
            case .line:
                if isAlwaysHidden {
                    // 双细线区分「总是隐藏」边界
                    NSBezierPath(
                        roundedRect: NSRect(x: cx - 2.3, y: cy - 5.0, width: 1.2, height: 10.0),
                        xRadius: 0.6,
                        yRadius: 0.6
                    ).fill()
                    NSBezierPath(
                        roundedRect: NSRect(x: cx + 1.1, y: cy - 5.0, width: 1.2, height: 10.0),
                        xRadius: 0.6,
                        yRadius: 0.6
                    ).fill()
                } else {
                    NSBezierPath(
                        roundedRect: NSRect(x: cx - 0.65, y: cy - 5.0, width: 1.3, height: 10.0),
                        xRadius: 0.65,
                        yRadius: 0.65
                    ).fill()
                }

            case .dot:
                if isAlwaysHidden {
                    NSBezierPath(ovalIn: NSRect(x: cx - 2.8, y: cy - 1.1, width: 2.2, height: 2.2)).fill()
                    NSBezierPath(ovalIn: NSRect(x: cx + 0.6, y: cy - 1.1, width: 2.2, height: 2.2)).fill()
                } else {
                    NSBezierPath(ovalIn: NSRect(x: cx - 1.2, y: cy - 1.2, width: 2.4, height: 2.4)).fill()
                }

            case .minimal:
                let alpha: CGFloat = isAlwaysHidden ? 0.28 : 0.18
                NSColor.labelColor.withAlphaComponent(alpha).setFill()
                NSBezierPath(ovalIn: NSRect(x: cx - 0.9, y: cy - 0.9, width: 1.8, height: 1.8)).fill()
            }

            return true
        }
        image.isTemplate = true
        return image
    }
}
