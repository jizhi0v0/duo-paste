import Testing
import Foundation
import GRDB
@testable import DuoPasteCore

private typealias DuoDB = DuoPasteCore.Database

@Suite("SearchQuery textFullSuffixes")
struct SearchQuerySuffixTests {
    private func makeDB() throws -> DuoDB {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("duo-suffix-\(UUID().uuidString)", isDirectory: true)
        let paths = Paths(root: root)
        paths.ensureExists()
        return try DuoDB(path: paths.mainDB)
    }

    private func insertFile(
        _ db: DuoDB,
        id: String,
        capturedAtNs: Int64,
        path: String,
        mime: String? = nil,
        sha: String? = "abc"  // 非空让 fold 不把它跟其他 .file 行折成一条
    ) throws {
        let it = Item(
            id: id,
            originDevice: "self",
            capturedAtNs: capturedAtNs,
            kind: .file,
            sourceAppName: "T",
            preview: path,
            textFull: path,
            blobSha256: sha == nil ? nil : sha! + "-" + id,
            blobSize: 100,
            blobMime: mime
        )
        try db.pool.write { conn in try it.insert(conn) }
    }

    private func insertImageData(
        _ db: DuoDB,
        id: String,
        capturedAtNs: Int64,
        sha: String
    ) throws {
        let it = Item(
            id: id,
            originDevice: "self",
            capturedAtNs: capturedAtNs,
            kind: .image,
            sourceAppName: "T",
            preview: nil,
            textFull: nil,
            blobSha256: sha,
            blobSize: 100,
            blobMime: "image/png"
        )
        try db.pool.write { conn in try it.insert(conn) }
    }

    @Test("textFullSuffixes 命中匹配后缀的 file 行")
    func suffixHitsJava() throws {
        let db = try makeDB()
        try insertFile(db, id: "a", capturedAtNs: 1_000, path: "/proj/main.java")
        try insertFile(db, id: "b", capturedAtNs: 2_000, path: "/proj/util.swift")
        try insertFile(db, id: "c", capturedAtNs: 3_000, path: "/proj/note.txt")

        let api = SearchAPI(database: db)
        let q = SearchQuery(textFullSuffixes: [".java"])
        let hits = try api.searchHits(q)
        #expect(hits.count == 1)
        #expect(hits.first?.0.id == "a")
    }

    @Test("多 suffix OR 关系")
    func multipleSuffixesOR() throws {
        let db = try makeDB()
        try insertFile(db, id: "a", capturedAtNs: 1_000, path: "/proj/main.java")
        try insertFile(db, id: "b", capturedAtNs: 2_000, path: "/proj/util.swift")
        try insertFile(db, id: "c", capturedAtNs: 3_000, path: "/proj/note.txt")

        let api = SearchAPI(database: db)
        let q = SearchQuery(textFullSuffixes: [".java", ".swift"])
        let hits = try api.searchHits(q)
        #expect(hits.count == 2)
        #expect(Set(hits.map { $0.0.id }) == ["a", "b"])
    }

    @Test("kinds + suffixes OR — 文本 OR java 文件")
    func kindOrSuffixOR() throws {
        let db = try makeDB()
        // 文本行
        let textIt = Item(id: "t", originDevice: "self", capturedAtNs: 1_000,
                          kind: .text, preview: "hello", textFull: "hello")
        try db.pool.write { try textIt.insert($0) }
        // java 文件
        try insertFile(db, id: "j", capturedAtNs: 2_000, path: "/x.java")
        // 不相关的 swift 文件
        try insertFile(db, id: "s", capturedAtNs: 3_000, path: "/y.swift")

        let api = SearchAPI(database: db)
        let q = SearchQuery(kinds: [.text], textFullSuffixes: [".java"])
        let hits = try api.searchHits(q)
        #expect(hits.count == 2)
        #expect(Set(hits.map { $0.0.id }) == ["t", "j"])
    }

    @Test("imageMerged 等价 — kinds=[.image] + fileSubKinds=[.imageFile] 命中两种存储")
    func imageMergedEquivalent() throws {
        let db = try makeDB()
        // 原生剪贴板图片
        try insertImageData(db, id: "native", capturedAtNs: 1_000, sha: "n1")
        // Finder 复制 .png 文件路径（kind=file + mime image/png）
        try insertFile(db, id: "filepng", capturedAtNs: 2_000, path: "/x.png", mime: "image/png")
        // 不相关的 swift 文件
        try insertFile(db, id: "sw", capturedAtNs: 3_000, path: "/y.swift")

        let api = SearchAPI(database: db)
        let q = SearchQuery(kinds: [.image], fileSubKinds: [.imageFile])
        let hits = try api.searchHits(q)
        #expect(hits.count == 2)
        #expect(Set(hits.map { $0.0.id }) == ["native", "filepng"])
    }

    @Test("count 跟 searchHits 口径一致（含 suffix 过滤）")
    func countConsistentWithHits() throws {
        let db = try makeDB()
        try insertFile(db, id: "a", capturedAtNs: 1_000, path: "/x.java")
        try insertFile(db, id: "b", capturedAtNs: 2_000, path: "/y.java")
        try insertFile(db, id: "c", capturedAtNs: 3_000, path: "/z.swift")

        let api = SearchAPI(database: db)
        let q = SearchQuery(textFullSuffixes: [".java"])
        let hits = try api.searchHits(q)
        let total = try api.count(q)
        #expect(hits.count == total)
        #expect(total == 2)
    }

    @Test("countByKind 在有 suffix 时只数符合 suffix 的行")
    func countByKindWithSuffix() throws {
        let db = try makeDB()
        // 文本行（不带 .java 后缀）
        let textIt = Item(id: "t", originDevice: "self", capturedAtNs: 1_000,
                          kind: .text, preview: "hello", textFull: "hello")
        try db.pool.write { try textIt.insert($0) }
        // java 文件 ×2
        try insertFile(db, id: "j1", capturedAtNs: 2_000, path: "/x.java")
        try insertFile(db, id: "j2", capturedAtNs: 3_000, path: "/y.java")
        // 不相关 swift 文件
        try insertFile(db, id: "s", capturedAtNs: 4_000, path: "/z.swift")

        let api = SearchAPI(database: db)
        let q = SearchQuery(textFullSuffixes: [".java"])
        let counts = try api.countByKind(q)
        // suffix 维度保留 → 计数只含 .java 行
        #expect(counts[.file] == 2)
        // text 行不带 .java 后缀，不该被计入
        #expect((counts[.text] ?? 0) == 0)
    }
}
