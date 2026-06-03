import Foundation

/// 预览容器身份。把 item id / kind / blob sha 一起编码，避免 UI 容器在不同条目间误复用。
enum PreviewIdentity {
    static func make(itemID: String, kindRawValue: String, blobSHA256: String?) -> String {
        [
            itemID,
            kindRawValue,
            blobSHA256 ?? "no-sha",
        ].joined(separator: "|")
    }
}
