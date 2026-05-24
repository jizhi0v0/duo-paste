import Foundation
import GRDB

/// `GET /search` 响应的 wire 形态。iOS client `JSONDecoder().decode(SearchPageWire.self, ...)`
/// 解。`items` 用自定义 `SearchHitWire`——每条同时含 Item 完整字段 + 可选 `snippet`
/// (FTS5 高亮片段,STX/ETX 包围匹配词)。**Codable 复用**:Item 已经 Codable,wire 字段
/// 直接对应 JSON 顶层(handler 走 itemToJSON 把 Item dict 跟 snippet 并平铺)
public struct SearchPageWire: Decodable, Sendable {
    public let ok: Bool
    /// **qualifier-filtered + fold 后的总数**(issue #41 之后语义校准):server 端走
    /// `searchHitsAndCount` 单次 fold-aware pass,先 FTS5 命中 → 跨 origin fold → 按
    /// `kinds` / `file_sub_kinds` / `text_suffixes` qualifier filter,然后 limit/offset 切页。
    /// `count` 是 **filter 之后、limit 之前** 的真实总数,跟 `items.count` 关系:
    /// `items.count = min(count, limit)`。UI 显"共 N 条"直接用本字段,跟 Mac chip 总数对齐
    public let count: Int
    public let items: [SearchHitWire]

    public init(ok: Bool, count: Int, items: [SearchHitWire]) {
        self.ok = ok
        self.count = count
        self.items = items
    }
}

/// 单条 /search hit。Item 字段平铺 + 可选 snippet。Item 直接走自身 Codable 解 Decoder,
/// snippet 通过同一份 container 旁路取出
public struct SearchHitWire: Decodable, Sendable {
    public let item: Item
    public let snippet: String?

    public init(item: Item, snippet: String?) {
        self.item = item
        self.snippet = snippet
    }

    private enum SnippetCodingKeys: String, CodingKey {
        case snippet
    }

    public init(from decoder: Decoder) throws {
        self.item = try Item(from: decoder)
        let c = try decoder.container(keyedBy: SnippetCodingKeys.self)
        self.snippet = try c.decodeIfPresent(String.self, forKey: .snippet)
    }
}

public struct SearchQuery: Sendable, Equatable {
    public var text: String?
    public var fromNs: Int64?
    public var toNs: Int64?
    public var kinds: [ItemKind]
    /// `.file` kind 的虚拟 sub-kind 过滤(视频/PDF/音频/图片文件)。语义上跟 `kinds`
    /// **OR 关系**——`kinds=[.text]` + `fileSubKinds=[.video]` 命中文本 OR 视频文件
    public var fileSubKinds: [FileSubKind]
    /// 文件扩展名后缀过滤（如 [".java", ".py"]）。跟 kinds / fileSubKinds **OR 关系**。
    /// 走 `LOWER(text_full) LIKE '%.java'`——FTS5 unicode61 tokenizer 对 `.` 不可靠，
    /// 用 LIKE 后缀匹配跟 sub-kind ext 路径同构。给 slash qualifier `/java /c /py` 用
    public var textFullSuffixes: [String]
    public var pinnedOnly: Bool
    public var includeDeleted: Bool
    public var limit: Int
    public var offset: Int

    public init(
        text: String? = nil,
        fromNs: Int64? = nil,
        toNs: Int64? = nil,
        kinds: [ItemKind] = [],
        fileSubKinds: [FileSubKind] = [],
        textFullSuffixes: [String] = [],
        pinnedOnly: Bool = false,
        includeDeleted: Bool = false,
        limit: Int = 200,
        offset: Int = 0
    ) {
        self.text = text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.fromNs = fromNs
        self.toNs = toNs
        self.kinds = kinds
        self.fileSubKinds = fileSubKinds
        self.textFullSuffixes = textFullSuffixes
        self.pinnedOnly = pinnedOnly
        self.includeDeleted = includeDeleted
        self.limit = limit
        self.offset = offset
    }
}

public struct SearchAPI: Sendable {
    public let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func search(_ q: SearchQuery) throws -> [Item] {
        try database.pool.read { db in
            try Self.fetch(db, query: q)
        }
    }

    /// 匹配词高亮分隔符。STX/ETX 是 ASCII 控制字符，几乎不会出现在剪贴板真实文本里——
    /// UI 拿到字符串按这两个 marker 切片、夹在中间的部分加粗。
    public static let snippetStartMarker = "\u{02}"
    public static let snippetEndMarker   = "\u{03}"

    /// 一次 SQL 同时返回 item + FTS snippet，**fold-aware**——跨 origin 同 text_full 的行
    /// 折成一条（capture 层 dedup 只防同 origin，跨 origin 兜底靠这一层；详 CLAUDE.md
    /// "文本永久 dedup"）。snippet 仅当 query.text 非空时填；其它情况第二元素为 nil。
    /// max tokens=8：紧密围绕匹配词，SwiftUI `lineLimit(2)` 一定能显示到高亮段。
    ///
    /// PR 6 之前还有 `searchUnion` 是"fold-aware"路径、`searchHits` 是"raw"路径，mesh
    /// 拓扑下 item 表本身就混 own + peer 行，raw 路径出来的总数跟对端不齐——直接合并
    /// 成单一 fold-aware 路径，删 raw 公开 API。
    public func searchHits(_ q: SearchQuery) throws -> [(Item, String?)] {
        try database.pool.read { db in
            try Self.fetchHitsFolded(db, query: q)
        }
    }

    /// 单次 fold-aware pass 同时返回 hits + total count——给"既要 list 也要 chip 总数"的
    /// 调用方(HTTP `/search` handler / SwiftUI 顶 chip)用。
    ///
    /// **性能**:跟 `searchHits + count` 分两次比起来,这里 fetchHitsFolded 只跑一次
    /// (limit=Int.max 拿全集),再 Swift 端切片到 (offset..<offset+limit) 给 hits,
    /// 全集 .count 直接当 total。10k 行 + FTS5 命中数千时省一倍 SQL+Swift fold 工。
    ///
    /// 等价性:total 跟 `count(q)` 一致(同源 fetchHitsFolded);hits 跟 `searchHits(q)`
    /// 一致(slice 顺序跟 fetchHitsFolded 内置 limit/offset 一致)。回归测试钉死
    public func searchHitsAndCount(_ q: SearchQuery) throws -> (hits: [(Item, String?)], total: Int) {
        try database.pool.read { db in
            // limit=Int.max + offset=0 → fetchHitsFolded 返回全部排序后的命中
            // (内部 needsPostFilter 时 oversample 本来就是 Int.max,所以这一改不增加开销)
            let allQuery = SearchQuery(
                text: q.text,
                fromNs: q.fromNs, toNs: q.toNs,
                kinds: q.kinds,
                fileSubKinds: q.fileSubKinds,
                textFullSuffixes: q.textFullSuffixes,
                pinnedOnly: q.pinnedOnly,
                includeDeleted: q.includeDeleted,
                limit: Int.max,
                offset: 0
            )
            let all = try Self.fetchHitsFolded(db, query: allQuery)
            let total = all.count
            let start = min(q.offset, all.count)
            let end = min(q.offset + q.limit, all.count)
            let sliced = start < end ? Array(all[start..<end]) : []
            return (sliced, total)
        }
    }

    /// Fold-aware fetch 内部实现：oversample raw（无 kinds/pinnedOnly 过滤）→ text-fold
    /// （跨 origin 同 text_full 折一条，pinned OR 聚合）→ 后置 kinds/pinnedOnly 过滤 →
    /// 排序契约（pinned/prefix24h/captured DESC）→ LIMIT/OFFSET。
    static func fetchHitsFolded(_ db: GRDB.Database, query q: SearchQuery) throws -> [(Item, String?)] {
        // pinnedOnly / kinds 必须在 text-fold **之后**按 winner 行的字段过滤——fold 会做 pinned
        // OR 聚合，过滤依据必须是聚合后 winner。否则：跨 origin 同文本一边 pinned=true 一边
        // false，子查询带 `pinned=1` 过滤后只剩 pinned 那条参与 fold，winner 不变；但 list /
        // countByKindUnion 走同源 oversample 流程要保证三者口径一致。
        //
        // pinnedOnly=true 或 q.kinds 非空时 oversample 必须无界——否则按时间倒序取 limit+offset
        // 行可能全是不该出现在结果里的类型/未 pin 状态，filter 后凑不齐 q.limit。剪贴板量级
        // 万级，Swift 端 fold 几毫秒，可接受。
        let needsPostFilter = q.pinnedOnly || !q.kinds.isEmpty || !q.fileSubKinds.isEmpty || !q.textFullSuffixes.isEmpty
        let oversampleLimit = needsPostFilter ? Int.max : (q.limit + q.offset)
        let oversample = SearchQuery(
            text: q.text,
            fromNs: q.fromNs, toNs: q.toNs,
            kinds: [], fileSubKinds: [], textFullSuffixes: [], pinnedOnly: false,
            includeDeleted: q.includeDeleted,
            limit: oversampleLimit,
            offset: 0
        )
        let raw = try fetchHitsRaw(db, query: oversample)

        // 文本永久 dedup：单表 item 内按 text_full 二次 fold。仅 blob_sha256 IS NULL 行参与
        // （即 text/url/file，"字节相等即同"），blob kind 不动——同 sha 图片多次复制可能是
        // 用户故意保留时间线。winner = max(capturedAtNs)，pinned 通过 OR 聚合（任一条 pinned
        // → fold 结果 pinned=true），符合"pin 是对内容的属性而非具体 row"心智。
        //
        // 必须在下面的 kind/pinned 后置 filter **之前**——pinned 聚合后 winner.pinned 才是
        // 正确的过滤依据。
        //
        // **契约定义在 `Item.foldByTextFull`(DuoPasteCore)** —— iOS HistoryStore.filtered
        // 也按同一份契约 fold,Mac/iOS UI 跨设备 dedup 行为对齐. 本路径因为要同时携带 FTS5
        // snippet (tuple `(Item, String?)`) 走自己的 fold 副本,逻辑必须与 `Item.foldByTextFull`
        // 严格一致——任何分叉都是 bug. 回归测试 `SearchFoldV7Tests` (Mac) + `ItemFoldTests` (核心)
        var byText: [String: (Item, String?)] = [:]
        var nonTextFolded: [(Item, String?)] = []
        nonTextFolded.reserveCapacity(raw.count)
        for hit in raw {
            let it = hit.0
            if it.blobSha256 == nil, let tf = it.textFull, !tf.isEmpty {
                if let existing = byText[tf] {
                    let winner = it.capturedAtNs > existing.0.capturedAtNs ? hit : existing
                    var w = winner.0
                    w.pinned = it.pinned || existing.0.pinned
                    byText[tf] = (w, winner.1)
                } else {
                    byText[tf] = hit
                }
            } else {
                nonTextFolded.append(hit)
            }
        }
        var deduped = Array(byText.values) + nonTextFolded

        // 按 winner 行的字段过滤——不可前置到子查询。countByKindUnion / countUnion 走同源
        // 不变量保证 chip 数字、count、list 三者口径一致。
        // kinds + fileSubKinds + textFullSuffixes 走 **OR** 关系——任一命中即保留(空 = 全保留)
        if !q.kinds.isEmpty || !q.fileSubKinds.isEmpty || !q.textFullSuffixes.isEmpty {
            let allowedKinds = Set(q.kinds)
            let subSet = Set(q.fileSubKinds)
            let suffixes = q.textFullSuffixes.map { $0.lowercased() }
            deduped = deduped.filter { hit in
                let item = hit.0
                if allowedKinds.contains(item.kind) { return true }
                if !subSet.isEmpty, item.kind == .file,
                   let sub = ItemClassifier.fileSubKind(item),
                   subSet.contains(sub) {
                    return true
                }
                if !suffixes.isEmpty, let tf = item.textFull?.lowercased(),
                   suffixes.contains(where: { tf.hasSuffix($0) }) {
                    return true
                }
                return false
            }
        }
        if q.pinnedOnly {
            deduped = deduped.filter { $0.0.pinned }
        }
        // 排序契约：pinned DESC → prefix DESC → captured_at_ns DESC。
        // prefix 分数跟 SQL 端 CASE 一致（preview 起始=2, text_full 起始=1, 否则 0）。
        let prefixText = q.text
        // 跟 SQL 端口径一致：24h 窗外的项 prefix 分数清零，强制走时间倒序。
        let nowNs = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        let windowNs: Int64 = 86_400 * 1_000_000_000
        func prefixScore(_ item: Item) -> Int {
            guard let t = prefixText, !t.isEmpty else { return 0 }
            if nowNs - item.capturedAtNs >= windowNs { return 0 }
            let needle = t.lowercased()
            if let pv = item.preview, pv.lowercased().hasPrefix(needle) { return 2 }
            if let tf = item.textFull, tf.lowercased().hasPrefix(needle) { return 1 }
            return 0
        }
        deduped.sort { lhs, rhs in
            if lhs.0.pinned != rhs.0.pinned { return lhs.0.pinned }
            let lp = prefixScore(lhs.0)
            let rp = prefixScore(rhs.0)
            if lp != rp { return lp > rp }
            return lhs.0.capturedAtNs > rhs.0.capturedAtNs
        }
        let start = min(q.offset, deduped.count)
        let end = min(q.offset + q.limit, deduped.count)
        guard start < end else { return [] }
        return Array(deduped[start..<end])
    }

    /// Raw 单表 fetch：纯 SQL，没有 Swift 端 fold。仅 `fetchHitsFolded` 内部 oversample
    /// 时用——公开 API 永远走 fold-aware 的 `searchHits`，跟对端口径一致
    private static func fetchHitsRaw(_ db: GRDB.Database, query q: SearchQuery) throws -> [(Item, String?)] {
        var wheres: [String] = []
        var args: [DatabaseValueConvertible] = []

        if !q.includeDeleted { wheres.append("item.deleted_at_ns IS NULL") }
        if let from = q.fromNs { wheres.append("item.captured_at_ns >= ?"); args.append(from) }
        if let to = q.toNs { wheres.append("item.captured_at_ns <= ?"); args.append(to) }
        if let kindPred = buildKindPredicate(q, args: &args) {
            wheres.append(kindPred)
        }
        if q.pinnedOnly { wheres.append("item.pinned = 1") }

        let useFTS: Bool
        if let text = q.text, let match = ftsQuery(from: text) {
            useFTS = true
            wheres.append("item_fts MATCH ?")
            args.append(match)
        } else {
            useFTS = false
        }

        let join = useFTS ? "JOIN item_fts ON item_fts.rowid = item.rowid" : ""
        // snippet 窗口 = match 前后各 N 个 token。FTS5 硬限 1..64,取上限 64
        // 让卡片尽量多带上下文;物理截断由 `lineLimit(20) + frame(height: 204)` 兜底
        let snippetCol = useFTS
            ? ", snippet(item_fts, -1, char(2), char(3), '…', 64) AS _snippet"
            : ""
        let prefixCol: String
        let needsPrefix = q.text != nil && ftsQuery(from: q.text!) != nil
        if needsPrefix {
            prefixCol = """
                , CASE
                    WHEN instr(LOWER(IFNULL(item.preview, '')), LOWER(?)) = 1 THEN 2
                    WHEN instr(LOWER(IFNULL(item.text_full, '')), LOWER(?)) = 1 THEN 1
                    ELSE 0
                  END AS _prefix
                """
            args.insert(contentsOf: [q.text! as DatabaseValueConvertible, q.text! as DatabaseValueConvertible], at: 0)
        } else {
            prefixCol = ""
        }
        // 时间窗：prefix-boost 仅对 24h 内的项生效。跨天的老内容（哪怕起头匹配）也按
        // 时间倒序排——剪贴板心智里"搜=找最近用过的"，不希望陈年老条目被翻上来。
        // SQLite 自带 strftime('%s','now')，避免 Swift 端再往 args 里塞 now_ns。
        let orderPrefix = needsPrefix
            ? "(CASE WHEN (CAST(strftime('%s','now') AS INTEGER) * 1000000000 - item.captured_at_ns) < 86400000000000 THEN _prefix ELSE 0 END) DESC, "
            : ""
        let whereClause = wheres.isEmpty ? "" : "WHERE " + wheres.joined(separator: " AND ")
        let sql = """
            SELECT item.*\(snippetCol)\(prefixCol)
            FROM item
            \(join)
            \(whereClause)
            ORDER BY item.pinned DESC, \(orderPrefix)item.captured_at_ns DESC
            LIMIT ? OFFSET ?
        """
        args.append(q.limit)
        args.append(q.offset)

        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        return try rows.map { row -> (Item, String?) in
            let item = try Item(row: row)
            let snippet: String? = useFTS ? row["_snippet"] : nil
            return (item, snippet)
        }
    }

    /// 当前 query 条件下匹配的真实总数（忽略 limit/offset，**fold-aware**）。
    /// UI 用来显示真实 counter，不受 200 cap 截断影响。跟 `searchHits` 同源走
    /// fold 路径——保证 list / total / chip 三者口径一致。
    public func count(_ q: SearchQuery) throws -> Int {
        try database.pool.read { db in
            let oversample = SearchQuery(
                text: q.text,
                fromNs: q.fromNs, toNs: q.toNs,
                kinds: q.kinds,
                fileSubKinds: q.fileSubKinds,
                textFullSuffixes: q.textFullSuffixes,
                pinnedOnly: q.pinnedOnly,
                includeDeleted: q.includeDeleted,
                limit: Int.max,
                offset: 0
            )
            return try Self.fetchHitsFolded(db, query: oversample).count
        }
    }

    /// 当前 (query / timeRange / pinnedOnly) 维度下，按 kind 分桶的 fold 后命中数。
    /// **忽略**输入 `q.kinds` + `q.fileSubKinds`——chip count 显示的是"如果我只点这个
    /// chip 会得到多少"，跟当前已选 chip 集合无关。否则多选时 count 来回跳，用户没法
    /// 判断稀疏类型。跟 `searchHits` / `count` 同源走 fold 路径，保证 chip / total / list 口径一致。
    public func countByKind(_ q: SearchQuery) throws -> [ItemKind: Int] {
        // textFullSuffixes 是搜索维度（用户输 /java 想看 java 文件），不是 chip 维度，
        // 跟 kinds/fileSubKinds 不同——保留进 stripped 让 chip count 反映"如果只选这个
        // chip + 当前搜索范围有多少"，而不是"忽略整个搜索范围"
        let stripped = SearchQuery(
            text: q.text,
            fromNs: q.fromNs, toNs: q.toNs,
            kinds: [],
            fileSubKinds: [],
            textFullSuffixes: q.textFullSuffixes,
            pinnedOnly: q.pinnedOnly,
            includeDeleted: q.includeDeleted,
            limit: Int.max, offset: 0
        )
        return try database.pool.read { db in
            let hits = try Self.fetchHitsFolded(db, query: stripped)
            var out: [ItemKind: Int] = [:]
            for hit in hits {
                out[hit.0.kind, default: 0] += 1
            }
            return out
        }
    }

    /// 按 file sub-kind 分桶的 fold 后命中数。同 `countByKind` 的语义——chip "视频 N"
    /// 显示假如**只**选视频会有多少条,忽略当前已选 chip。返回所有 FileSubKind 的 entry
    /// (缺的填 0),让 chip "0" 状态可见
    public func countByFileSubKind(_ q: SearchQuery) throws -> [FileSubKind: Int] {
        let stripped = SearchQuery(
            text: q.text,
            fromNs: q.fromNs, toNs: q.toNs,
            kinds: [],
            fileSubKinds: [],
            textFullSuffixes: q.textFullSuffixes,
            pinnedOnly: q.pinnedOnly,
            includeDeleted: q.includeDeleted,
            limit: Int.max, offset: 0
        )
        return try database.pool.read { db in
            let hits = try Self.fetchHitsFolded(db, query: stripped)
            var out: [FileSubKind: Int] = [:]
            for k in FileSubKind.allCases { out[k] = 0 }
            for hit in hits where hit.0.kind == .file {
                if let sub = ItemClassifier.fileSubKind(hit.0) {
                    out[sub, default: 0] += 1
                }
            }
            return out
        }
    }

    /// 构造 kind + fileSubKinds 的 OR'd WHERE 谓词。返回 nil 表示无 kind 过滤。
    /// args 通过 inout 追加占位符值,调用方拼到自己的 args 序列里。
    /// 注意:占位符顺序必须跟 args 追加顺序严格对齐
    private static func buildKindPredicate(_ q: SearchQuery, args: inout [DatabaseValueConvertible]) -> String? {
        var clauses: [String] = []
        if !q.kinds.isEmpty {
            let p = q.kinds.map { _ in "?" }.joined(separator: ",")
            clauses.append("item.kind IN (\(p))")
            args.append(contentsOf: q.kinds.map { $0.rawValue })
        }
        for sub in q.fileSubKinds {
            let pred = subKindSQL(sub, args: &args)
            clauses.append("(item.kind = 'file' AND \(pred))")
        }
        for suffix in q.textFullSuffixes {
            args.append("%" + suffix.lowercased())
            clauses.append("LOWER(IFNULL(item.text_full,'')) LIKE ?")
        }
        guard !clauses.isEmpty else { return nil }
        return clauses.count == 1 ? clauses[0] : "(" + clauses.joined(separator: " OR ") + ")"
    }

    /// 单个 FileSubKind 的 SQL 谓词:mime OR 路径后缀 LIKE。多 ext 用 OR 串联,
    /// LIKE 用 `LOWER(IFNULL(text_full,''))` 兼容空字段 + 大小写
    private static func subKindSQL(_ sub: FileSubKind, args: inout [DatabaseValueConvertible]) -> String {
        let mimeClause: String
        let exts: [String]
        switch sub {
        case .video:
            args.append("video/%")
            mimeClause = "item.blob_mime LIKE ?"
            exts = [".mp4", ".m4v", ".mov"]
        case .pdf:
            args.append("application/pdf")
            mimeClause = "item.blob_mime = ?"
            exts = [".pdf"]
        case .audio:
            args.append("audio/%")
            mimeClause = "item.blob_mime LIKE ?"
            exts = [".mp3", ".m4a", ".aac", ".wav", ".flac", ".aiff", ".aif", ".ogg", ".opus"]
        case .imageFile:
            args.append("image/%")
            mimeClause = "item.blob_mime LIKE ?"
            exts = [".png", ".jpg", ".jpeg", ".heic", ".heif", ".gif", ".webp", ".tiff", ".tif", ".bmp", ".svg"]
        }
        let likeClauses = exts.map { ext -> String in
            args.append("%" + ext)
            return "LOWER(IFNULL(item.text_full,'')) LIKE ?"
        }
        return "(" + ([mimeClause] + likeClauses).joined(separator: " OR ") + ")"
    }

    /// 把用户输入的自由文本转成 FTS5 MATCH 表达式。
    /// 策略：按空白拆词，每个 token 转义双引号后作为前缀短语，AND 连接。
    /// 比如 `foo bar"baz` → `"foo"* AND "bar""baz"*`
    public static func ftsQuery(from text: String) -> String? {
        let tokens = text
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { token -> String in
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\"*"
        }.joined(separator: " AND ")
    }

    public static func fetch(_ db: GRDB.Database, query q: SearchQuery) throws -> [Item] {
        var wheres: [String] = []
        var args: [DatabaseValueConvertible] = []

        if !q.includeDeleted {
            wheres.append("item.deleted_at_ns IS NULL")
        }
        if let from = q.fromNs {
            wheres.append("item.captured_at_ns >= ?")
            args.append(from)
        }
        if let to = q.toNs {
            wheres.append("item.captured_at_ns <= ?")
            args.append(to)
        }
        if let kindPred = buildKindPredicate(q, args: &args) {
            wheres.append(kindPred)
        }
        if q.pinnedOnly {
            wheres.append("item.pinned = 1")
        }

        let useFTS: Bool
        if let text = q.text, let match = ftsQuery(from: text) {
            useFTS = true
            wheres.append("item_fts MATCH ?")
            args.append(match)
        } else {
            useFTS = false
        }

        let join = useFTS ? "JOIN item_fts ON item_fts.rowid = item.rowid" : ""
        let needsPrefix = q.text != nil && ftsQuery(from: q.text!) != nil
        let prefixCol: String
        if needsPrefix {
            prefixCol = """
                , CASE
                    WHEN instr(LOWER(IFNULL(item.preview, '')), LOWER(?)) = 1 THEN 2
                    WHEN instr(LOWER(IFNULL(item.text_full, '')), LOWER(?)) = 1 THEN 1
                    ELSE 0
                  END AS _prefix
                """
            args.insert(contentsOf: [q.text! as DatabaseValueConvertible, q.text! as DatabaseValueConvertible], at: 0)
        } else {
            prefixCol = ""
        }
        // 时间窗：prefix-boost 仅对 24h 内的项生效。跨天的老内容（哪怕起头匹配）也按
        // 时间倒序排——剪贴板心智里"搜=找最近用过的"，不希望陈年老条目被翻上来。
        // SQLite 自带 strftime('%s','now')，避免 Swift 端再往 args 里塞 now_ns。
        let orderPrefix = needsPrefix
            ? "(CASE WHEN (CAST(strftime('%s','now') AS INTEGER) * 1000000000 - item.captured_at_ns) < 86400000000000 THEN _prefix ELSE 0 END) DESC, "
            : ""
        let whereClause = wheres.isEmpty ? "" : "WHERE " + wheres.joined(separator: " AND ")
        let sql = """
            SELECT item.*\(prefixCol)
            FROM item
            \(join)
            \(whereClause)
            ORDER BY item.pinned DESC, \(orderPrefix)item.captured_at_ns DESC
            LIMIT ? OFFSET ?
        """
        args.append(q.limit)
        args.append(q.offset)

        return try Item.fetchAll(db, sql: sql, arguments: StatementArguments(args))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
