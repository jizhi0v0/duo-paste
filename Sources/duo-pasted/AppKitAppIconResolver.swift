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
        // 走 cgImage(forProposedRect:context:hints:) 在主代表上 rasterize 一次,失败兜底
        // 取 representations 第一个 bitmap rep
        let targetSize = NSSize(width: pngPixelSize, height: pngPixelSize)
        var rect = NSRect(origin: .zero, size: targetSize)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            // fallback: 找到任意一个 NSBitmapImageRep 直接 PNG encode
            for rep in image.representations {
                if let bitmap = rep as? NSBitmapImageRep,
                   let data = bitmap.representation(using: .png, properties: [:]) {
                    return data
                }
            }
            return nil
        }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        bitmap.size = targetSize
        return bitmap.representation(using: .png, properties: [.compressionFactor: 0.85 as NSNumber])
    }
}
