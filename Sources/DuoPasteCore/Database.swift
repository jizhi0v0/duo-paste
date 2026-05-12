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
}
