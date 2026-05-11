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

        return m
    }

    /// 一键 WAL checkpoint，用于 snapshot 前刷盘
    public func checkpoint() throws {
        _ = try pool.writeWithoutTransaction { db in
            try db.checkpoint(.truncate)
        }
    }
}
