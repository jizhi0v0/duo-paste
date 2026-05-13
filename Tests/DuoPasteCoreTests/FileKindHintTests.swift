import Testing
import Foundation
@testable import DuoPasteCore

@Test func detectsCommonImageExtensions() {
    #expect(fileLooksLikeImage(path: "/Users/x/screenshot.png"))
    #expect(fileLooksLikeImage(path: "/Users/x/photo.jpg"))
    #expect(fileLooksLikeImage(path: "/Users/x/photo.jpeg"))
    #expect(fileLooksLikeImage(path: "/Users/x/photo.heic"))
    #expect(fileLooksLikeImage(path: "/Users/x/photo.heif"))
    #expect(fileLooksLikeImage(path: "/Users/x/animation.gif"))
    #expect(fileLooksLikeImage(path: "/Users/x/banner.webp"))
    #expect(fileLooksLikeImage(path: "/Users/x/scan.tiff"))
    #expect(fileLooksLikeImage(path: "/Users/x/scan.tif"))
    #expect(fileLooksLikeImage(path: "/Users/x/legacy.bmp"))
    #expect(fileLooksLikeImage(path: "/Users/x/icon.svg"))
}

@Test func caseInsensitive() {
    #expect(fileLooksLikeImage(path: "/Users/x/IMG.PNG"))
    #expect(fileLooksLikeImage(path: "/Users/x/Photo.JPG"))
    #expect(fileLooksLikeImage(path: "/Users/x/Photo.Heic"))
}

@Test func rejectsNonImageExtensions() {
    #expect(!fileLooksLikeImage(path: "/Users/x/notes.txt"))
    #expect(!fileLooksLikeImage(path: "/Users/x/script.sh"))
    #expect(!fileLooksLikeImage(path: "/Users/x/doc.pdf"))
    // 设计源文件不算"图片"（用户决策）
    #expect(!fileLooksLikeImage(path: "/Users/x/design.psd"))
    #expect(!fileLooksLikeImage(path: "/Users/x/design.ai"))
    #expect(!fileLooksLikeImage(path: "/Users/x/design.sketch"))
}

@Test func rejectsMultiplePaths() {
    // 多文件复制 → PasteboardWatcher step 1 用 \n join，hint 表达不了"部分是图片"
    let multi = """
    /Users/x/a.png
    /Users/x/b.txt
    """
    #expect(!fileLooksLikeImage(path: multi))
}

@Test func rejectsEmptyOrBlankInput() {
    #expect(!fileLooksLikeImage(path: ""))
    #expect(!fileLooksLikeImage(path: "   "))
    #expect(!fileLooksLikeImage(path: "\t\n"))
}

@Test func rejectsPathWithoutExtension() {
    #expect(!fileLooksLikeImage(path: "/Users/x/binary"))
    #expect(!fileLooksLikeImage(path: "/Users/x/file"))
}

@Test func trimsWhitespaceBeforeChecking() {
    #expect(fileLooksLikeImage(path: "  /Users/x/photo.png  "))
}
