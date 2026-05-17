import Foundation
import AppKit
import DuoPasteCore

/// AppKit-side icon resolver — `AppIconStore.IconResolver` 的注入实现。
///
/// 从 NSWorkspace 拿到 bundleID 对应 NSImage,渲染成 128×128 PNG 字节(iOS 高分辨率
/// 显示 22pt @3x = 66pt 实际像素,128 给足以应对未来更大的显示场景)。
///
/// 调用线程任意 — NSWorkspace.urlForApplication / icon(forFile:) +
/// NSBitmapImageRep 序列化都已是线程安全 read-only 操作。
enum AppKitAppIconResolver {
    /// 已知 bundleID 黑名单(跟 SearchView.AppIconCache.nonAppBundleIDs 同源)。
    /// loginwindow / WindowServer / dock 不是真"来源 app",LaunchServices 给 icon
    /// 也是占位符 — 直接返 nil 让 client 走 kind icon fallback
    private static let nonAppBundleIDs: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.WindowServer",
        "com.apple.dock",
        Item.selfSourceAppSentinel,
    ]

    /// 输出 PNG 边长 — iOS HistoryCellView 显示 22pt,在 @3x 设备上 = 66pt 真实像素,
    /// 128 留足未来放大空间(预览 / iPad detail)。再大没意义,反而 cache 字节膨胀
    private static let pngPixelSize: CGFloat = 128

    /// `AppIconStore` 注入用的 resolver 闭包工厂 — 一个进程一份就够,内部纯无状态
    static func resolver() -> AppIconStore.IconResolver {
        return { bundleID in
            pngBytes(forBundleID: bundleID)
        }
    }

    /// 单次查询:bundleID → PNG Data?。app 未装 / sandbox 拒绝 / NSImage 拿不到 bitmap
    /// → nil(AppIconStore 把 nil 缓存为已知缺失,避免反复重 IO)
    static func pngBytes(forBundleID bundleID: String) -> Data? {
        if nonAppBundleIDs.contains(bundleID) { return nil }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        return encodePNG(icon)
    }

    private static func encodePNG(_ image: NSImage) -> Data? {
        // NSImage 自身是 vector-ish (含多 representation),要落到固定像素 bitmap 才能 PNG encode。
        //
        // **不要走 cgImage(forProposedRect:)** 也**不要让 NSImage 自己挑 rep**——
        // NSWorkspace.icon 返回的 NSImage 默认 size=32 / 64,小 rep 可能把 dock baseline
        // shadow / 倒影烘进字节,iOS 端 22pt 显示时底部能看到一条暗色 strip。
        //
        // 显式找最大的 NSBitmapImageRep(现代 .icns 通常含 1024×1024 干净 squircle rep,
        // 没 shadow——shadow 是 Dock 动态加的)→ 用 rep.draw 缩到 128×128 目标 bitmap →
        // PNG encode。没 NSBitmapImageRep(罕见,生成式 icon / symbol 类)→ 回退到
        // image.draw 让 NSImage 自己挑
        let pixel = Int(pngPixelSize)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixel, pixelsHigh: pixel,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 32
        ) else {
            return nil
        }
        bitmap.size = NSSize(width: pngPixelSize, height: pngPixelSize)
        guard let ctx = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        let target = NSRect(x: 0, y: 0, width: pngPixelSize, height: pngPixelSize)

        let largestRep = image.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .max(by: { ($0.pixelsWide * $0.pixelsHigh) < ($1.pixelsWide * $1.pixelsHigh) })

        if let rep = largestRep {
            let src = NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
            rep.draw(in: target, from: src, operation: .copy, fraction: 1.0,
                     respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        } else {
            image.draw(in: target, from: NSRect(origin: .zero, size: image.size),
                       operation: .copy, fraction: 1.0)
        }
        return bitmap.representation(using: .png, properties: [.compressionFactor: 0.85 as NSNumber])
    }
}
