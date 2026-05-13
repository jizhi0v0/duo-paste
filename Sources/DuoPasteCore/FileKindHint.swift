import Foundation

/// 文件路径后缀启发：判该 file kind item 的路径"看起来"是张图片。
/// 仅用于 UI hint badge（"文件 · 图片"），**不**升级 kind / 不参与 chip 计数 / 不写 DB。
///
/// 弱信号：用户可能从 Notion / Markdown / 代码里复制 `screenshot.png` 这种**文字串**，
/// 后缀是图片但实体只是字符串路径，BlobStore 里没字节。strict kind 保持 `.file` 是对的，
/// hint badge 只是让"这是图片文件"在列表里一眼可见。
///
/// 接受的扩展名集合保守，常见 raster + 主流 metadata-rich 格式。SVG 算图片但不算 raster；
/// 不接 .ai / .psd / .sketch / .xd 这种设计文件 —— 它们是"图片源文件"不是"图片"
public func fileLooksLikeImage(path: String) -> Bool {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return false }
    // 多行 = 一次复制多个文件路径（PasteboardWatcher step 1 用 \n join 多 URL），
    // 单 row hint 表达不了"一组里只有部分是图片"，干脆不显示
    if trimmed.contains("\n") || trimmed.contains("\r") { return false }
    let lower = trimmed.lowercased()
    let exts: [String] = [
        ".png", ".jpg", ".jpeg",
        ".heic", ".heif",
        ".gif", ".webp",
        ".tiff", ".tif",
        ".bmp", ".svg",
    ]
    for ext in exts where lower.hasSuffix(ext) {
        return true
    }
    return false
}
