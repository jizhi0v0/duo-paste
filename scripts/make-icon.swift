#!/usr/bin/env swift
// 生成 Resources/AppIcon.icns —— 图标是**画出来的**，不是二进制黑盒：改配色/构图直接改这里
// 重跑，别手工 PS 一张覆盖进去（否则下次要改就没有源了）。
//
//     swift scripts/make-icon.swift            # 写回 Resources/AppIcon.icns
//     swift scripts/make-icon.swift /tmp/out   # 只出 PNG 预览到指定目录
//
// 构图：双卡叠放，呼应菜单栏的 `doc.on.clipboard`(StatusBarController)。石墨配色是工具类
// app 的质感，不跟内容抢眼。
//
// **每个尺寸独立矢量渲染**，不是把 1024 缩下去：16/32 这种小尺寸缩放后文字线会糊成灰块，
// 所以 ≤64 时换成更少更粗的线（Apple 自家图标同样按尺寸简化）。
import AppKit
import Foundation

// MARK: - 配色

let plateTop = NSColor(srgbRed: 0.36, green: 0.39, blue: 0.44, alpha: 1)
let plateBottom = NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 1)
/// 前卡上的文字线：冷灰,比纯灰多一点蓝让图标不死板
let lineColor = NSColor(srgbRed: 0.38, green: 0.42, blue: 0.50, alpha: 1)

// MARK: - 基础几何

/// macOS 图标网格：1024 画布里圆角方形占 824,四周留出投影/呼吸区
let plateRatio: CGFloat = 824.0 / 1024.0

/// 系统图标的连续圆角用超椭圆逼近(n 越大越方)。roundedRect 的圆弧角在 512 以上一眼就看得出不对
func squirclePath(rect: CGRect, n: CGFloat = 6.2) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = rect.midX + a * pow(abs(ct), 2 / n) * (ct < 0 ? -1 : 1)
        let y = rect.midY + b * pow(abs(st), 2 / n) * (st < 0 ? -1 : 1)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: - 渲染

func renderIcon(size: CGFloat) -> CGImage {
    let px = Int(size)
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    // 所有绝对量(投影偏移/模糊半径)都按这个比例缩,否则小尺寸会被投影糊掉
    let k = size / 1024

    let plateSide = size * plateRatio
    let plate = CGRect(x: (size - plateSide) / 2, y: (size - plateSide) / 2,
                       width: plateSide, height: plateSide)
    let platePath = squirclePath(rect: plate)

    // 底板投影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18 * k), blur: 40 * k,
                  color: NSColor.black.withAlphaComponent(0.30).cgColor)
    ctx.addPath(platePath)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // 底板渐变
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let grad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [plateTop.cgColor, plateBottom.cgColor] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(grad, start: CGPoint(x: plate.minX, y: plate.maxY),
                           end: CGPoint(x: plate.maxX, y: plate.minY), options: [])
    // 顶部内高光
    let hi = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [NSColor.white.withAlphaComponent(0.18).cgColor,
                 NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(hi, start: CGPoint(x: 0, y: plate.maxY),
                           end: CGPoint(x: 0, y: plate.midY), options: [])
    ctx.restoreGState()

    // 上缘发丝高光——系统图标都有这条,少了会显得"平"
    if size >= 64 {
        ctx.saveGState()
        ctx.addPath(platePath)
        ctx.clip()
        ctx.addPath(platePath)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
        ctx.setLineWidth(3 * k)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // 前景一律夹在底板内,卡片偏移再大也不会溢出圆角
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()

    let cardW = plate.width * 0.42, cardH = plate.height * 0.52
    let radius = cardW * 0.14

    // 后卡:半透明白,右上偏移
    let back = CGRect(x: plate.midX - cardW / 2 + plate.width * 0.11,
                      y: plate.midY - cardH / 2 + plate.height * 0.11,
                      width: cardW, height: cardH)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 26 * k,
                  color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(roundedRect(back, radius))
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.62).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // 前卡:实心白,左下偏移
    let front = CGRect(x: plate.midX - cardW / 2 - plate.width * 0.09,
                       y: plate.midY - cardH / 2 - plate.height * 0.09,
                       width: cardW, height: cardH)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * k), blur: 30 * k,
                  color: NSColor.black.withAlphaComponent(0.32).cgColor)
    ctx.addPath(roundedRect(front, radius))
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // 文字线:小尺寸换成两条更粗的,否则缩下去只剩一团灰
    let compact = size <= 64
    let count = compact ? 2 : 4
    let lineH = front.height * (compact ? 0.10 : 0.055)
    let gap = lineH * (compact ? 2.2 : 1.9)
    let inset = front.width * (compact ? 0.16 : 0.13)
    let widths: [CGFloat] = compact ? [0.85, 0.60] : [0.74, 0.86, 0.55, 0.68]
    let top = front.maxY - inset - lineH
    ctx.setFillColor(lineColor.cgColor)
    for i in 0..<count {
        let w = (front.width - inset * 2) * widths[i % widths.count]
        let r = CGRect(x: front.minX + inset, y: top - CGFloat(i) * gap, width: w, height: lineH)
        ctx.addPath(roundedRect(r, lineH / 2))
        ctx.fillPath()
    }
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 1)
    }
    try data.write(to: url)
}

// MARK: - 出图

let fm = FileManager.default
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let previewDir = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : nil

if let previewDir {
    try fm.createDirectory(at: previewDir, withIntermediateDirectories: true)
    for s: CGFloat in [16, 32, 64, 128, 256, 512, 1024] {
        try writePNG(renderIcon(size: s), to: previewDir.appendingPathComponent("icon-\(Int(s)).png"))
    }
    print("预览 PNG → \(previewDir.path)")
    exit(0)
}

// iconset：每个逻辑尺寸的 1x/2x。@2x 是同一张矢量按物理像素重画,不是放大
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }

for logical in [16, 32, 128, 256, 512] {
    try writePNG(renderIcon(size: CGFloat(logical)),
                 to: iconset.appendingPathComponent("icon_\(logical)x\(logical).png"))
    try writePNG(renderIcon(size: CGFloat(logical * 2)),
                 to: iconset.appendingPathComponent("icon_\(logical)x\(logical)@2x.png"))
}

let out = repoRoot.appendingPathComponent("Resources/AppIcon.icns")
try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil 失败\n".data(using: .utf8)!)
    exit(1)
}
let bytes = (try? fm.attributesOfItem(atPath: out.path))?[.size] as? Int ?? 0
print("AppIcon.icns → \(out.path) (\(bytes) bytes)")
