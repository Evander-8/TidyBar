#!/usr/bin/env swift
/**
 * [INPUT]: 依赖 AppKit、CoreGraphics、Foundation
 * [OUTPUT]: 在指定输出目录生成符合 macOS 规范的 AppIcon.iconset 10 档高清 PNG 图标集
 * [POS]: scripts 的图标资产生成工具，为 build_app.sh 提供原生矢量 AppIcon 源
 * [PROTOCOL]: Update this header on change, then check GEMINI.md
 */

import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: generate_icon.swift <output-iconset-dir>\n", stderr)
    exit(1)
}

let outputDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let specs: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func renderIcon(pixels: Int) -> CGImage? {
    let size = CGFloat(pixels)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }

    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    let inset = size * 0.08
    let iconRect = canvas.insetBy(dx: inset, dy: inset)
    let cornerRadius = iconRect.width * 0.225

    // 1. 深邃夜空蓝圆角底色
    let bgPath = CGPath(roundedRect: iconRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()

    let bgColors = [
        NSColor(calibratedRed: 0.07, green: 0.11, blue: 0.21, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.12, green: 0.22, blue: 0.40, alpha: 1).cgColor
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0, 1]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: iconRect.minX, y: iconRect.minY),
            end: CGPoint(x: iconRect.maxX, y: iconRect.maxY),
            options: []
        )
    }
    ctx.restoreGState()

    // 2. 外框玻璃微高光
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
    ctx.setLineWidth(max(1, size * 0.014))
    ctx.strokePath()
    ctx.restoreGState()

    // 3. 顶部磨砂菜单栏胶囊条
    let barRect = CGRect(
        x: iconRect.minX + iconRect.width * 0.13,
        y: iconRect.midY + iconRect.height * 0.06,
        width: iconRect.width * 0.74,
        height: iconRect.height * 0.22
    )
    let barPath = CGPath(
        roundedRect: barRect,
        cornerWidth: barRect.height * 0.45,
        cornerHeight: barRect.height * 0.45,
        transform: nil
    )
    ctx.saveGState()
    ctx.addPath(barPath)
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.16).cgColor)
    ctx.fillPath()
    ctx.addPath(barPath)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.32).cgColor)
    ctx.setLineWidth(max(1, size * 0.012))
    ctx.strokePath()
    ctx.restoreGState()

    // 4. 菜单栏内部左侧微点（被收纳区）与右侧青蓝展开箭头
    let dotRadius = max(1.2, barRect.height * 0.16)
    let cy = barRect.midY
    for idx in 0..<3 {
        let dotX = barRect.minX + barRect.width * (0.20 + CGFloat(idx) * 0.14)
        let alpha: CGFloat = idx == 0 ? 0.38 : (idx == 1 ? 0.60 : 0.85)
        ctx.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        ctx.fillEllipse(in: CGRect(x: dotX - dotRadius, y: cy - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
    }

    // 竖线分割符
    let sepX = barRect.minX + barRect.width * 0.62
    let sepH = barRect.height * 0.52
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.55).cgColor)
    ctx.fill(CGRect(x: sepX - max(0.8, size * 0.01), y: cy - sepH / 2, width: max(1.5, size * 0.022), height: sepH))

    // 亮青蓝收纳箭头
    let arrowCenterX = barRect.minX + barRect.width * 0.80
    let arrowArm = barRect.height * 0.24
    ctx.saveGState()
    ctx.setStrokeColor(NSColor(calibratedRed: 0.34, green: 0.82, blue: 1.0, alpha: 1).cgColor)
    ctx.setLineWidth(max(1.5, size * 0.042))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: arrowCenterX + arrowArm * 0.55, y: cy + arrowArm))
    ctx.addLine(to: CGPoint(x: arrowCenterX - arrowArm * 0.55, y: cy))
    ctx.addLine(to: CGPoint(x: arrowCenterX + arrowArm * 0.55, y: cy - arrowArm))
    ctx.strokePath()
    ctx.restoreGState()

    // 5. 下方二级下拉栏悬浮卡片剪影
    let subRect = CGRect(
        x: iconRect.minX + iconRect.width * 0.24,
        y: iconRect.minY + iconRect.height * 0.19,
        width: iconRect.width * 0.52,
        height: iconRect.height * 0.22
    )
    let subPath = CGPath(
        roundedRect: subRect,
        cornerWidth: subRect.height * 0.38,
        cornerHeight: subRect.height * 0.38,
        transform: nil
    )
    ctx.saveGState()
    ctx.addPath(subPath)
    ctx.setFillColor(NSColor(calibratedRed: 0.34, green: 0.82, blue: 1.0, alpha: 0.22).cgColor)
    ctx.fillPath()
    ctx.addPath(subPath)
    ctx.setStrokeColor(NSColor(calibratedRed: 0.34, green: 0.82, blue: 1.0, alpha: 0.80).cgColor)
    ctx.setLineWidth(max(1, size * 0.014))
    ctx.strokePath()

    let subDotR = max(1.1, subRect.height * 0.16)
    for idx in 0..<3 {
        let sx = subRect.minX + subRect.width * (0.28 + CGFloat(idx) * 0.22)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor)
        ctx.fillEllipse(in: CGRect(x: sx - subDotR, y: subRect.midY - subDotR, width: subDotR * 2, height: subDotR * 2))
    }
    ctx.restoreGState()

    return ctx.makeImage()
}

for spec in specs {
    guard let image = renderIcon(pixels: spec.pixels) else {
        fputs("Failed to render \(spec.name)\n", stderr)
        exit(1)
    }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        fputs("Failed to encode \(spec.name)\n", stderr)
        exit(1)
    }
    try pngData.write(to: outputDir.appendingPathComponent(spec.name))
}
