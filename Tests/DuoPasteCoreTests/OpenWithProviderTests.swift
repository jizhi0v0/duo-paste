import Testing
import Foundation
import UniformTypeIdentifiers
@testable import DuoPasteCore

/// 纯逻辑测试 —— 不调 NSWorkspace(不可控,不同机器装的 app 不一样)。
/// 重点覆盖 kind→category 映射 + rank 排序 dedup + filterTextEditors 黑名单
private func makeItem(
    kind: ItemKind,
    textFull: String? = nil,
    preview: String? = nil,
    blobSha256: String? = nil,
    blobMime: String? = nil
) -> Item {
    Item(
        id: UUID().uuidString,
        originDevice: "test",
        capturedAtNs: 1,
        kind: kind,
        preview: preview,
        textFull: textFull,
        blobSha256: blobSha256,
        blobMime: blobMime
    )
}

@Test func categoryTextKindsAreTextEditor() {
    let texts: [ItemKind] = [.text, .rtf, .html]
    for kind in texts {
        let item = makeItem(kind: kind, textFull: "hello")
        let cat = OpenWithProvider.category(for: item)
        #expect(cat == .textEditor, "\(kind) 应映射到 .textEditor")
    }
}

@Test func categoryURLKindIsBrowser() {
    let item = makeItem(kind: .url, textFull: "https://example.com", preview: "https://example.com")
    #expect(OpenWithProvider.category(for: item) == .browser)
}

@Test func categoryImageKindIsViewer() {
    // 有 mime → 用 mime 推
    let withMime = makeItem(kind: .image, blobSha256: String(repeating: "a", count: 64), blobMime: "image/png")
    if case .viewer(let ut) = OpenWithProvider.category(for: withMime) {
        #expect(ut == UTType(mimeType: "image/png"))
    } else {
        Issue.record("image+mime 应是 .viewer")
    }
    // 无 mime → 退到 .image 父类
    let noMime = makeItem(kind: .image, blobSha256: String(repeating: "b", count: 64))
    if case .viewer(let ut) = OpenWithProvider.category(for: noMime) {
        #expect(ut == .image)
    } else {
        Issue.record("image 无 mime 应是 .viewer(.image)")
    }
}

@Test func categoryFileKindBlobButNoLocalPathFallsBackToViewer() {
    // textFull 路径不存在 + 有 blob + mime → .viewer(.pdf)
    let item = makeItem(
        kind: .file,
        textFull: "/tmp/this-path-definitely-does-not-exist-\(UUID().uuidString).pdf",
        blobSha256: String(repeating: "c", count: 64),
        blobMime: "application/pdf"
    )
    if case .viewer(let ut) = OpenWithProvider.category(for: item) {
        #expect(ut == UTType(mimeType: "application/pdf"))
    } else {
        Issue.record("file 无本地路径 + 有 mime 应是 .viewer")
    }
}

@Test func categoryFileKindLocalPathExistsIsFilePath() throws {
    // 建一个真实存在的临时文件
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("dpw-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let realFile = dir.appendingPathComponent("real.txt")
    try Data("hi".utf8).write(to: realFile)
    defer { try? FileManager.default.removeItem(at: dir) }

    let item = makeItem(kind: .file, textFull: realFile.path)
    if case .filePath(let url) = OpenWithProvider.category(for: item) {
        #expect(url.path == realFile.path)
    } else {
        Issue.record("file 本地路径存在应是 .filePath")
    }
}

@Test func categoryFileKindNoMimeUsesFilenameExtension() {
    // 路径不存在 + 无 mime → 退到 filename ext
    let item = makeItem(
        kind: .file,
        textFull: "/tmp/missing-\(UUID().uuidString).pdf"
    )
    if case .viewer(let ut) = OpenWithProvider.category(for: item) {
        // .pdf 后缀 → UTType.pdf
        #expect(ut.conforms(to: .pdf) || ut == UTType(filenameExtension: "pdf"))
    } else {
        Issue.record("file 仅有后缀线索应是 .viewer")
    }
}

@Test func rankPlacesDefaultFirstAndDedups() {
    let appA = URL(fileURLWithPath: "/Applications/AppA.app")
    let appB = URL(fileURLWithPath: "/Applications/AppB.app")
    let appC = URL(fileURLWithPath: "/Applications/AppC.app")
    // urls 列表里 default 在中间,rank 应该把它提到首位 + 后面去重
    let ranked = OpenWithProvider.rank(
        urls: [appA, appB, appC, appA],   // 末位重复 appA 测 dedup
        defaultURL: appB
    )
    #expect(ranked.count == 3)
    #expect(ranked[0].bundleURL == appB)
    #expect(ranked[0].isDefault == true)
    #expect(ranked[1].isDefault == false)
    #expect(ranked[2].isDefault == false)
    // appB 不该再出现一次
    let appBCount = ranked.filter { $0.bundleURL == appB }.count
    #expect(appBCount == 1)
}

@Test func rankWithoutDefaultJustPreservesOrder() {
    let appA = URL(fileURLWithPath: "/Applications/AppA.app")
    let appB = URL(fileURLWithPath: "/Applications/AppB.app")
    let ranked = OpenWithProvider.rank(urls: [appA, appB], defaultURL: nil)
    #expect(ranked.count == 2)
    #expect(ranked[0].bundleURL == appA)
    #expect(ranked[1].bundleURL == appB)
    #expect(ranked.allSatisfy { !$0.isDefault })
}

@Test func filterTextEditorsRemovesBlacklisted() {
    let apps: [OpenWithApp] = [
        OpenWithApp(
            bundleURL: URL(fileURLWithPath: "/Applications/VSCode.app"),
            bundleID: "com.microsoft.VSCode",
            displayName: "Visual Studio Code",
            isDefault: false
        ),
        OpenWithApp(
            bundleURL: URL(fileURLWithPath: "/Applications/Word.app"),
            bundleID: "com.microsoft.Word",
            displayName: "Microsoft Word",
            isDefault: false
        ),
        OpenWithApp(
            bundleURL: URL(fileURLWithPath: "/Applications/Pages.app"),
            bundleID: "com.apple.iWork.Pages",
            displayName: "Pages",
            isDefault: false
        ),
        OpenWithApp(
            bundleURL: URL(fileURLWithPath: "/Applications/TextEdit.app"),
            bundleID: "com.apple.TextEdit",
            displayName: "TextEdit",
            isDefault: false
        ),
        OpenWithApp(
            bundleURL: URL(fileURLWithPath: "/Applications/Preview.app"),
            bundleID: "com.apple.Preview",
            displayName: "Preview",
            isDefault: true   // 验证黑名单不放过 default
        ),
    ]
    let filtered = OpenWithProvider.filterTextEditors(apps)
    let ids = filtered.compactMap(\.bundleID)
    #expect(ids.contains("com.microsoft.VSCode"))
    #expect(ids.contains("com.apple.TextEdit"))
    #expect(!ids.contains("com.microsoft.Word"))
    #expect(!ids.contains("com.apple.iWork.Pages"))
    #expect(!ids.contains("com.apple.Preview"), "Preview 即使是 default 也该被过滤")
}

@Test func filterTextEditorsKeepsUnknownBundleIDs() {
    // 无 bundleID(损坏 / 系统返回不全)的 app 不该被过滤掉,保守保留
    let apps: [OpenWithApp] = [
        OpenWithApp(
            bundleURL: URL(fileURLWithPath: "/Applications/Mystery.app"),
            bundleID: nil,
            displayName: "Mystery",
            isDefault: false
        ),
    ]
    let filtered = OpenWithProvider.filterTextEditors(apps)
    #expect(filtered.count == 1)
}

@Test func displayNameFallsBackToFinderName() {
    // 不存在的 path → Bundle(url:) 返回 nil → 走 FileManager.displayName fallback
    let url = URL(fileURLWithPath: "/Applications/NoSuchApp.app")
    let name = OpenWithProvider.displayName(for: url)
    #expect(!name.isEmpty)
}
