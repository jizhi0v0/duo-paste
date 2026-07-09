import Foundation

/// 预览容器身份。把 item id / kind / blob sha 一起编码，避免 UI 容器在不同条目间误复用。
/// **必须 public**——iOS app（DuoPasteApp 模块）跨模块 import DuoPasteCore 调用，internal
/// 在 iOS 编译不可见。Mac 端 `@testable import` 看得见 internal 所以 swift test 不报，掩盖此漏
public enum PreviewIdentity {
    public static func make(itemID: String, kindRawValue: String, blobSHA256: String?) -> String {
        [
            itemID,
            kindRawValue,
            blobSHA256 ?? "no-sha",
        ].joined(separator: "|")
    }
}
