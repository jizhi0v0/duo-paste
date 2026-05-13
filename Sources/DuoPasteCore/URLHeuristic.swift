import Foundation

/// 判别字符串是否应当被视作 URL。命中后 PasteboardWatcher 把 kind 升为 `.url`，
/// 让浏览器 Cmd+C 选中 URL 文本时不再落到 `.text` 兜底分支。
///
/// 严格规则（避免误判）：
///   - trim 后 scheme 严格等于 "http" 或 "https"
///   - 单行（无 `\n` / `\r`）：排除"URL + 说明文字"复合文本
///   - 无 raw whitespace（含 \t）：URL 里 space 必须 %20 编码；裸 whitespace 通常是
///     "URL + 后接文字"——SQL backfill 端 `text_full NOT LIKE '% %'` 只挡 space，Swift 端
///     必须连 \t 一起挡，否则 "https://x.com<TAB>note" 在 Swift 路径会被错升 .url
///   - URL(string:) 解析成功
///   - host 校验：非空、无连续 `..`、不以 `.` 起止、字符限于 `[a-zA-Z0-9.-]`
///     （IDN 已 punycode 成 `xn--...`；IPv6 形如 `::1` 含 `:` 会被排除——剪贴板里裸 IPv6
///     URL 极罕见，保守换误判面收紧）
///
/// 不接受 `www.` / 裸 host / file://：
///   - 裸 host 误判风险高（"config.json" 也匹配大多数 TLD 启发）
///   - file:// 走 PasteboardWatcher 第 1 步 `readObjects([NSURL.self], fileURLsOnly:true)`
///   - 其他 scheme（ftp/ssh/git/mailto/custom 协议）暂不归类，留 `.text` 兜底
public func looksLikeURL(_ s: String) -> Bool {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return false }
    if trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) {
        return false
    }
    guard let url = URL(string: trimmed) else { return false }
    guard let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https"
    else { return false }
    guard let host = url.host, !host.isEmpty else { return false }
    if host.hasPrefix(".") || host.hasSuffix(".") { return false }
    if host.contains("..") { return false }
    let allowedHostChars = CharacterSet.lowercaseLetters
        .union(.uppercaseLetters)
        .union(.decimalDigits)
        .union(CharacterSet(charactersIn: ".-"))
    if host.unicodeScalars.contains(where: { !allowedHostChars.contains($0) }) { return false }
    return true
}
