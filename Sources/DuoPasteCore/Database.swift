import Foundation
import GRDB

public enum DatabaseRole: Sendable {
    case primary
    case client
}

public struct Database: Sendable {
    public let pool: DatabasePool
    public let role: DatabaseRole

    public init(path: URL, role: DatabaseRole = .client) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            // WAL + foreign keys + busy timeout
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA busy_timeout = 3000")
        }
        self.pool = try DatabasePool(path: path.path, configuration: config)
        self.role = role
        try Self.migrator.migrate(pool)
    }

    public static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1_initial") { db in
            try db.execute(sql: """
                CREATE TABLE item (
                    id              TEXT PRIMARY KEY,
                    origin_device   TEXT NOT NULL,
                    captured_at_ns  INTEGER NOT NULL,
                    ingested_at_ns  INTEGER,
                    kind            TEXT NOT NULL,
                    source_app      TEXT,
                    source_app_name TEXT,
                    preview         TEXT,
                    text_full       TEXT,
                    blob_sha256     TEXT,
                    blob_size       INTEGER,
                    blob_mime       TEXT,
                    pinned          INTEGER NOT NULL DEFAULT 0,
                    deleted_at_ns   INTEGER,
                    push_state      TEXT NOT NULL DEFAULT 'pending',
                    push_attempts   INTEGER NOT NULL DEFAULT 0,
                    last_push_error TEXT
                ) STRICT;
            """)

            try db.execute(sql: """
                CREATE INDEX idx_item_captured
                    ON item(captured_at_ns DESC)
                    WHERE deleted_at_ns IS NULL;
            """)
            try db.execute(sql: """
                CREATE INDEX idx_item_pinned_captured
                    ON item(pinned, captured_at_ns DESC)
                    WHERE deleted_at_ns IS NULL;
            """)
            try db.execute(sql: """
                CREATE INDEX idx_item_kind_captured
                    ON item(kind, captured_at_ns DESC)
                    WHERE deleted_at_ns IS NULL;
            """)
            try db.execute(sql: """
                CREATE INDEX idx_item_push
                    ON item(push_state)
                    WHERE push_state != 'acked';
            """)
            try db.execute(sql: """
                CREATE INDEX idx_item_blob_sha
                    ON item(blob_sha256)
                    WHERE blob_sha256 IS NOT NULL;
            """)

            try db.execute(sql: """
                CREATE VIRTUAL TABLE item_fts USING fts5(
                    text_full,
                    preview,
                    source_app_name,
                    content='item',
                    content_rowid='rowid',
                    tokenize='unicode61 remove_diacritics 2'
                );
            """)

            // contentless-external 模式触发器：让 item 的写入自动反映到 FTS。
            try db.execute(sql: """
                CREATE TRIGGER item_ai AFTER INSERT ON item BEGIN
                    INSERT INTO item_fts(rowid, text_full, preview, source_app_name)
                    VALUES (new.rowid, new.text_full, new.preview, new.source_app_name);
                END;
            """)
            try db.execute(sql: """
                CREATE TRIGGER item_ad AFTER DELETE ON item BEGIN
                    INSERT INTO item_fts(item_fts, rowid, text_full, preview, source_app_name)
                    VALUES ('delete', old.rowid, old.text_full, old.preview, old.source_app_name);
                END;
            """)
            try db.execute(sql: """
                CREATE TRIGGER item_au AFTER UPDATE ON item BEGIN
                    INSERT INTO item_fts(item_fts, rowid, text_full, preview, source_app_name)
                    VALUES ('delete', old.rowid, old.text_full, old.preview, old.source_app_name);
                    INSERT INTO item_fts(rowid, text_full, preview, source_app_name)
                    VALUES (new.rowid, new.text_full, new.preview, new.source_app_name);
                END;
            """)
        }

        // v2: mirror 模式预留 schema。M2 阶段建表不用，M3 pull worker 启用时直接写入。
        // 提前建表的好处：M2 上线后真实 DB 已经有这些表，M3 不再需要二次 migration。
        m.registerMigration("v2_mirror") { db in
            // item_mirror 与 item 字段同步（除 push_*），额外加 mirrored_at_ns（拉到的时刻）。
            // 不混入 item 是为了保留"item 只装本机 origin"的语义；promote 时
            //   INSERT OR IGNORE INTO item SELECT ... FROM item_mirror 即完成晋升。
            try db.execute(sql: """
                CREATE TABLE item_mirror (
                    id              TEXT PRIMARY KEY,
                    origin_device   TEXT NOT NULL,
                    captured_at_ns  INTEGER NOT NULL,
                    ingested_at_ns  INTEGER,
                    kind            TEXT NOT NULL,
                    source_app      TEXT,
                    source_app_name TEXT,
                    preview         TEXT,
                    text_full       TEXT,
                    blob_sha256     TEXT,
                    blob_size       INTEGER,
                    blob_mime       TEXT,
                    pinned          INTEGER NOT NULL DEFAULT 0,
                    deleted_at_ns   INTEGER,
                    mirrored_at_ns  INTEGER NOT NULL
                ) STRICT;
            """)

            try db.execute(sql: """
                CREATE INDEX idx_mirror_captured
                    ON item_mirror(captured_at_ns DESC)
                    WHERE deleted_at_ns IS NULL;
            """)
            try db.execute(sql: """
                CREATE INDEX idx_mirror_kind_captured
                    ON item_mirror(kind, captured_at_ns DESC)
                    WHERE deleted_at_ns IS NULL;
            """)
            try db.execute(sql: """
                CREATE INDEX idx_mirror_blob_sha
                    ON item_mirror(blob_sha256)
                    WHERE blob_sha256 IS NOT NULL;
            """)

            // 独立 FTS 表，搜索时 UNION ALL 与 item_fts 合并，
            // 避免合表后 trigger 需要识别来源、复杂度暴涨。
            try db.execute(sql: """
                CREATE VIRTUAL TABLE item_mirror_fts USING fts5(
                    text_full,
                    preview,
                    source_app_name,
                    content='item_mirror',
                    content_rowid='rowid',
                    tokenize='unicode61 remove_diacritics 2'
                );
            """)

            try db.execute(sql: """
                CREATE TRIGGER item_mirror_ai AFTER INSERT ON item_mirror BEGIN
                    INSERT INTO item_mirror_fts(rowid, text_full, preview, source_app_name)
                    VALUES (new.rowid, new.text_full, new.preview, new.source_app_name);
                END;
            """)
            try db.execute(sql: """
                CREATE TRIGGER item_mirror_ad AFTER DELETE ON item_mirror BEGIN
                    INSERT INTO item_mirror_fts(item_mirror_fts, rowid, text_full, preview, source_app_name)
                    VALUES ('delete', old.rowid, old.text_full, old.preview, old.source_app_name);
                END;
            """)
            try db.execute(sql: """
                CREATE TRIGGER item_mirror_au AFTER UPDATE ON item_mirror BEGIN
                    INSERT INTO item_mirror_fts(item_mirror_fts, rowid, text_full, preview, source_app_name)
                    VALUES ('delete', old.rowid, old.text_full, old.preview, old.source_app_name);
                    INSERT INTO item_mirror_fts(rowid, text_full, preview, source_app_name)
                    VALUES (new.rowid, new.text_full, new.preview, new.source_app_name);
                END;
            """)

            // Pull watermark：换 primary 时（不同 primary_id）cursor 自然重置 → 从 0 重拉。
            try db.execute(sql: """
                CREATE TABLE pull_cursor (
                    primary_id      TEXT PRIMARY KEY,
                    cursor_ns       INTEGER NOT NULL,
                    updated_at_ns   INTEGER NOT NULL
                ) STRICT;
            """)
        }

        // v3: /since 用的复合索引。WHERE ingested_at_ns IS NOT NULL 跟 SinceAPI 的查询条件
        // 一致，partial index 占盘小、命中走 index-only seek+scan，30s pull worker 不再
        // 触发 item 全表扫 + filesort。`(ingested_at_ns, id)` 跟 cursor 的二元 tiebreak 对齐。
        m.registerMigration("v3_since_index") { db in
            try db.execute(sql: """
                CREATE INDEX idx_item_ingested
                    ON item(ingested_at_ns, id)
                    WHERE ingested_at_ns IS NOT NULL;
            """)
        }

        // v4: pull_cursor 加 cursor_id。SinceCursor 是 (ns, id) 二元，少了 id 在同 ns 多行
        // 场景下会反复重拉同 ns 段（INSERT OR REPLACE 幂等但浪费带宽 + 极端情况 limit
        // 永远卡在同 ns 死循环）。`DEFAULT ''` 对应 SinceCursor.zero 的 id。
        m.registerMigration("v4_pull_cursor_id") { db in
            try db.execute(sql: """
                ALTER TABLE pull_cursor ADD COLUMN cursor_id TEXT NOT NULL DEFAULT '';
            """)
        }

        // v5: primary 任期 lineage。每次 `duo-pasted promote-to-primary` 写两行：
        //   1. (self_device, now, NULL)            ── 本机当前任期开始
        //   2. (old_primary_id, 0, now)            ── 闭老 primary 任期（started=0 = "未知何时开始"）
        // PK = (device_id, started_at_ns) 让一个 device 多次任期可记。
        //
        // audit-push 读这张表按 row.capturedAtNs 落在哪段 `[started_at_ns, ended_at_ns)`
        // 区间挑出该时刻的 active primary，dedup 候选必须 origin 严格 == 这个 device_id。
        // 跨任期碰撞被挡住；空 lineage / 时间未覆盖 / 期望 primary == self 的 stale 边界
        // 回退 "origin != self" 启发式保单 primary 部署零回归。详 AuditPush.swift。
        //
        // 本 migration 只建表；写入逻辑在 Admin.promoteToPrimary。
        m.registerMigration("v5_primary_lineage") { db in
            try db.execute(sql: """
                CREATE TABLE primary_lineage (
                    device_id     TEXT NOT NULL,
                    started_at_ns INTEGER NOT NULL,
                    ended_at_ns   INTEGER,
                    PRIMARY KEY (device_id, started_at_ns)
                ) STRICT;
            """)
        }

        // v6: 两件事一起做——
        //
        // 1. 加 `ocr_state TEXT NULL` 到 item / item_mirror。是给后续 OCR worker 留的状态位。
        //    取值：'pending' | 'done' | 'failed' | 'skipped'，NULL = 非 image kind / 无需 OCR。
        //    必须有这一列，否则 worker 区分不出"没扫过"vs"扫过但图里没字"——前者要扫，后者
        //    跳过；区分不出"失败"vs"成功无文本"——前者要重试，后者终态。
        //
        //    OCR 文本本身复用现有 `text_full`（FTS5 已索引 + UPDATE trigger 已挂），
        //    不需要新列也不需要新 FTS 表。worker 在未来某个 PR 加，本 migration 只埋 schema。
        //
        //    backfill：已有 image 行全部标 'pending'，让 worker 上线后慢慢扫历史。
        //
        // 2. URL 文本误分类回填。浏览器 Cmd+C URL 文本只写 .string 不写 NSURL 对象，
        //    PasteboardWatcher 第 5 步抓不到 → 落第 6 步 → kind=text。本期同时修了 capture
        //    路径让新数据直接 kind=url；这里把历史 text 行里"trimmed 是 http(s):// 起头
        //    单行"的也改成 url。GLOB 比 LIKE 高效（无 ESCAPE），换行检测排除 raw RTF /
        //    multi-line markdown 误判。
        //
        //    **不 bump `ingested_at_ns`**：本机改 own-origin 行的分类是"修正"不是"新数据"，
        //    其它 client 拉到自己的新数据时 capture 已经正确分类；老数据分类差异只在本机
        //    chip 计数上有体感，不需要全网同步。
        //
        //    **不需要重 rebuild FTS**：FTS5 trigger 挂在所有列上，但 `kind` 不在 FTS 索引列里，
        //    所以 trigger 触发会重新 index 一次（无害）；search 走 `kind IN (?)` 直接读 item
        //    表的 kind 列，立即生效。
        m.registerMigration("v6_url_and_ocr_state") { db in
            try db.execute(sql: "ALTER TABLE item ADD COLUMN ocr_state TEXT;")
            try db.execute(sql: "ALTER TABLE item_mirror ADD COLUMN ocr_state TEXT;")

            try db.execute(sql: """
                UPDATE item
                SET ocr_state = 'pending'
                WHERE kind = 'image' AND ocr_state IS NULL;
            """)
            try db.execute(sql: """
                UPDATE item_mirror
                SET ocr_state = 'pending'
                WHERE kind = 'image' AND ocr_state IS NULL;
            """)

            // Swift 端 backfill 调 looksLikeURL —— 跟 capture 路径同源判断，避免 SQL GLOB
            // 表达不出的 host 严格性漏判（codex review round 1 P1 #1）：
            //   - 'https:///path'        ── GLOB 'https://?*' 接受（`?` = 任意单字符，`/` 也算）
            //                                但 URL.host=nil → looksLikeURL 拒收
            //   - 'https://x.com<TAB>y'  ── GLOB 不挡 \t；looksLikeURL 严格 contains(\t) 拒收
            //   - '  https://x.com  '    ── GLOB 不接受（前导空白），looksLikeURL trim 后接受
            //   - 'HTTPS://x.com'        ── GLOB 大小写敏感漏掉，looksLikeURL .lowercased() 接受
            //
            // 一次单机 backfill，行数级别 1k-10k，逐行 UPDATE 在事务内 commit 也够；
            // 真撞到 100k 量级再换批量 IN clause
            for table in ["item", "item_mirror"] {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, text_full FROM \(table)
                    WHERE kind = 'text' AND text_full IS NOT NULL
                """)
                for row in rows {
                    guard let id: String = row["id"],
                          let txt: String = row["text_full"]
                    else { continue }
                    if looksLikeURL(txt) {
                        try db.execute(
                            sql: "UPDATE \(table) SET kind = 'url' WHERE id = ?",
                            arguments: [id]
                        )
                    }
                }
            }
        }

        // v7: mesh 拓扑合表。primary/client 模型废弃，每台 Mac 都是 peer。
        //
        // 1) 合表 item_mirror → item，mirror 行强制 push_state='acked'（这些行已经在 primary
        //    上 ingest 完成；mesh 拓扑下 push_state 列 PR 4 才删，PR 1 期间仍存在，必须给它
        //    一个有效终态值，否则升级期间 push_state 路径误把 mirror 行当 pending 重推）
        // 2) 兜底 stamp ingested_at_ns IS NULL 行（合表后混入 + 旧 client own-origin 行残留）。
        //    必须 Swift 端逐行调 nextIngestNs 保严格单增——纯 SQL 一次性 UPDATE 不行
        //    （详 Database.nextIngestNs 不变量）
        // 3) DROP item_mirror 全套：triggers / FTS 虚表 / partial indexes / 主表
        // 4) pull_cursor PK primary_id → peer_device_id（rename + 迁数据；mesh 拓扑下每个 peer
        //    一行 cursor，原 primary_id 字段名语义不再对）
        // 5) DROP primary_lineage（mesh 拓扑下无任期概念，audit-push PR 4 才删，期间该表读 SQL
        //    运行时挂 + 对应测试可挂——plan PR 1 字面接受）
        //
        // push_state / push_attempts / last_push_error 列 + idx_item_push 在 PR 1 期间**保留**，
        // PR 4 v8 migration 再 DROP。
        m.registerMigration("v7_mesh_consolidation") { db in
            // step 1: 合 item_mirror → item。INSERT OR IGNORE 让 id 冲突时 own 行赢
            // （own 是源头数据更可信，mirror 是镜像可能漏更新）。强制 push_state='acked'
            // 避免后续 PushWorker 误把 mirror 行重推
            try db.execute(sql: """
                INSERT OR IGNORE INTO item (
                    id, origin_device, captured_at_ns, ingested_at_ns, kind,
                    source_app, source_app_name, preview, text_full,
                    blob_sha256, blob_size, blob_mime,
                    pinned, deleted_at_ns,
                    push_state, push_attempts, last_push_error,
                    ocr_state
                )
                SELECT
                    id, origin_device, captured_at_ns, ingested_at_ns, kind,
                    source_app, source_app_name, preview, text_full,
                    blob_sha256, blob_size, blob_mime,
                    pinned, deleted_at_ns,
                    'acked', 0, NULL,
                    ocr_state
                FROM item_mirror;
            """)

            // step 2: 兜底 stamp ingested_at_ns IS NULL。逐行 nextIngestNs 单增，
            // 按 captured_at_ns ASC 顺序保 stamp 顺序 = 用户感知顺序（之后 /since
            // cursor 推进时 peer 拉到的也是这个顺序）
            let nullRows = try Row.fetchAll(db, sql: """
                SELECT id FROM item
                WHERE ingested_at_ns IS NULL
                ORDER BY captured_at_ns ASC, id ASC
            """)
            for row in nullRows {
                guard let id: String = row["id"] else { continue }
                let now = Clock.nowNs()
                let ns = try Self.nextIngestNs(db, now: now)
                try db.execute(sql: """
                    UPDATE item
                    SET ingested_at_ns = ?,
                        push_state = 'acked',
                        push_attempts = 0,
                        last_push_error = NULL
                    WHERE id = ?
                """, arguments: [ns, id])
            }

            // step 3: drop mirror 相关
            try db.execute(sql: "DROP TRIGGER IF EXISTS item_mirror_au;")
            try db.execute(sql: "DROP TRIGGER IF EXISTS item_mirror_ad;")
            try db.execute(sql: "DROP TRIGGER IF EXISTS item_mirror_ai;")
            try db.execute(sql: "DROP TABLE IF EXISTS item_mirror_fts;")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_mirror_blob_sha;")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_mirror_kind_captured;")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_mirror_captured;")
            try db.execute(sql: "DROP TABLE IF EXISTS item_mirror;")

            // step 4: pull_cursor PK 重建（primary_id → peer_device_id）
            try db.execute(sql: """
                CREATE TABLE pull_cursor_v7 (
                    peer_device_id  TEXT PRIMARY KEY,
                    cursor_ns       INTEGER NOT NULL,
                    cursor_id       TEXT NOT NULL DEFAULT '',
                    updated_at_ns   INTEGER NOT NULL
                ) STRICT;
            """)
            try db.execute(sql: """
                INSERT INTO pull_cursor_v7 (peer_device_id, cursor_ns, cursor_id, updated_at_ns)
                SELECT primary_id, cursor_ns, cursor_id, updated_at_ns FROM pull_cursor;
            """)
            try db.execute(sql: "DROP TABLE pull_cursor;")
            try db.execute(sql: "ALTER TABLE pull_cursor_v7 RENAME TO pull_cursor;")

            // step 5: drop primary_lineage（mesh 拓扑下无任期；audit-push 代码 PR 4 才清）
            try db.execute(sql: "DROP TABLE IF EXISTS primary_lineage;")
        }

        return m
    }

    /// 在 write 事务内调用，返回**严格大于**当前 MAX(item.ingested_at_ns) 的时间戳。
    /// 用于 primary 给新 ingest 的 item 打 `ingested_at_ns`，保证：
    ///
    ///     commit 顺序 == ingested_at_ns 顺序
    ///
    /// 这是 /since cursor 的正确性前提。否则两路 `pool.write` 在 writer 队列里排队时，
    /// 先打时间戳再排队 commit 会出现 "晚 commit 但 ns 更小" → reader 推进 cursor 后
    /// 永远漏掉那一行。详见 RemoteIngester / CaptureService 的调用点。
    ///
    /// `now` 通常是 `Clock.nowNs()`；wall clock 倒退或同毫秒内多次调用时，本函数会
    /// 用 `MAX+1` 顶上去保证严格单增。
    public static func nextIngestNs(_ db: GRDB.Database, now: Int64) throws -> Int64 {
        let prev = try Int64.fetchOne(db, sql: "SELECT MAX(ingested_at_ns) FROM item") ?? 0
        return Swift.max(now, prev &+ 1)
    }

    /// 在 item 表里找「本机近时间已有同内容」候选，用于 sync 层跨设备 dedup。
    ///
    /// 场景：mbp + mini 同一 Apple ID 登录开了 macOS Universal Clipboard，mbp 复制内容 X
    /// 后 100-200ms 内 mini 端 watcher 通过 Continuity 同步看到 changeCount 变化，也独立
    /// capture 了 X（origin=mini）。然后两边各自 push/pull 这条，UI union 看到 id 不同
    /// 但内容相同的两条——byID dedup 救不了。
    ///
    /// 治本思路（A）：primary 的 RemoteIngester 收 push 时调本函数查"本机 origin=primary
    /// 自己的同内容在 ±windowNs 内是否已存"，命中 → 把这次 push 当 Continuity 副本拒收。
    /// 治本思路（B）：client 的 PullWorker 把 origin≠self 的 mirror 行写表前调本函数查
    /// "本机 origin=self 同内容是否已存"，命中 → skip mirror 写入。
    ///
    /// 两端都需要 hook，单端救不全：A 让 primary item 表干净但 mbp UI 还会看到自己 own
    /// + mini mirror；B 让 client UI 干净但 primary item 表仍有冗余。
    ///
    /// blob 类型按 sha256 比对；text 类型按 text_full 全等比对（不算 hash 避免存额外字段
    /// 同时 text_full ≤ 512KB capture cap 比对成本可接受）。`ownDeviceID` 限定只看自家
    /// origin——找别人的会跟正常 mirror sync 路径耦合（PullWorker 已经在写 mirror）。
    public static func findNearbyOwnContent(
        _ db: GRDB.Database,
        kind: ItemKind,
        textFull: String?,
        blobSha256: String?,
        ownDeviceID: String,
        capturedAtNs: Int64,
        windowNs: Int64
    ) throws -> Item? {
        let floor = capturedAtNs &- windowNs
        let ceiling = capturedAtNs &+ windowNs
        let base = Item
            .filter(Column("kind") == kind.rawValue)
            .filter(Column("origin_device") == ownDeviceID)
            .filter(Column("captured_at_ns") >= floor)
            .filter(Column("captured_at_ns") <= ceiling)
            .filter(Column("deleted_at_ns") == nil)
            .order(Column("captured_at_ns").desc)

        if let sha = blobSha256, !sha.isEmpty {
            return try base.filter(Column("blob_sha256") == sha).fetchOne(db)
        }
        guard let text = textFull, !text.isEmpty else { return nil }
        return try base.filter(Column("text_full") == text).fetchOne(db)
    }

    /// 一键 WAL checkpoint，用于 snapshot 前刷盘
    public func checkpoint() throws {
        _ = try pool.writeWithoutTransaction { db in
            try db.checkpoint(.truncate)
        }
    }

    /// 切换 item.pinned。仅对 origin_device == selfDeviceID 的行生效——mirror 行
    /// （别的机器产生的）不能 pin，由调用方在 UI 层先判断。这里在 DB 层再守一道是
    /// 防御性：即使 UI 误传 mirror id 也不会改写跨设备行的 pinned。
    ///
    /// writer tx 内 bump `ingested_at_ns`，让 PullWorker 通过 /since 把变更回放到其他
    /// 设备的 item_mirror。primary 上调 → 全局可见；client 上调 → 仅本机生效
    /// （RemoteIngester 不更新已存在的 id，M2 契约"item 一旦 ingest 就不可变"。
    /// 跨设备 pin 同步留到将来 /update 路由）。
    ///
    /// Returns: `true` 代表实际 UPDATE 了一行；`false` = item 不存在 / 非 own-origin /
    /// 已是目标状态。**false 不是错误**，是幂等结果，调用方按需 refresh UI 即可
    @discardableResult
    public func setPinned(
        id: String,
        pinned: Bool,
        selfDeviceID: String,
        now: Int64
    ) throws -> Bool {
        try pool.write { db in
            guard let item = try Item.filter(Column("id") == id).fetchOne(db) else {
                return false
            }
            guard item.originDevice == selfDeviceID else {
                return false
            }
            if item.pinned == pinned { return false }
            let ts = try Self.nextIngestNs(db, now: now)
            try db.execute(sql: """
                UPDATE item
                SET pinned = ?, ingested_at_ns = ?
                WHERE id = ?
            """, arguments: [pinned ? 1 : 0, ts, id])
            return true
        }
    }
}
