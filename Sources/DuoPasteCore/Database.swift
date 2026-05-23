import Foundation
import GRDB

public struct Database: Sendable {
    public let pool: DatabasePool

    public init(path: URL) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            // WAL + foreign keys + busy timeout
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA busy_timeout = 3000")
        }
        self.pool = try DatabasePool(path: path.path, configuration: config)
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

        // v8: 删 push_* 列。PR 3 落地后所有 cursor 更新走 mesh /since + WS 通知，
        // 不再有 push 链路；保留 push_state 列等于占盘 + 让 Item.Codable 还得维护字段。
        //
        // 用 ALTER DROP COLUMN（SQLite 3.35+，macOS 14 自带 3.43+ 满足）。FTS5 trigger
        // 不引用这三列，无需重建。
        m.registerMigration("v8_drop_push_columns") { db in
            try db.execute(sql: "DROP INDEX IF EXISTS idx_item_push;")
            try db.execute(sql: "ALTER TABLE item DROP COLUMN push_state;")
            try db.execute(sql: "ALTER TABLE item DROP COLUMN push_attempts;")
            try db.execute(sql: "ALTER TABLE item DROP COLUMN last_push_error;")
        }

        // v9: 把"从 blob 内容派生出来的辅助索引文本"从 text_full 拆出来成独立列
        // `extracted_text`，并加 `extracted_text_source` 标这段文本是 OCR / 字幕 / PDF 文字层
        // 哪种 extractor 产出的（当前只有 'ocr'，未来加字幕/PDF text/ASR 时复用本列）。
        //
        // **核心动机**：v6 当年决定让 image kind 的 `text_full` 装 OCR 文本（FTS5 trigger
        // 复用零成本）。但 text_full 的契约本来是"原始可粘贴文本"——
        //   - text/url/rtf/html → 原文
        //   - file → 路径列表（Cmd+V 时写回 NSPasteboard 当 file URL）
        //   - image → 字节才是可粘贴主体，textFull 闲着 → 当时塞了 OCR 文本
        // 副作用是 image kind 的 textFull 语义跟其他 kind 不一致；PasteMerge.joinTextual
        // 加了 image-kind-special-cased 走 preview 兜底分支。
        //
        // v9 之后语义重新干净：
        //   - text_full   ：原始可粘贴文本（image kind 永远 NULL；其他 kind 不变）
        //   - extracted_text ：从 blob 派生的辅助索引文本（OCR/字幕/PDF text/ASR/...）
        //   - FTS5 索引列 = text_full + preview + source_app_name + extracted_text
        //
        // 顺手解锁 **file kind + image-blob 也能 OCR**（解决"用户从 Finder 复制 .png 文件，
        // 搜索框搜图里的字搜不出"的 gap）—— OCRWorker 之后会扩 fetchPending 谓词，本
        // migration 把存量 71 行本机 file+image-blob 标 ocr_state='pending' 让 worker 重扫。
        //
        // **不变量**：
        // 1. text_full 搬迁是单向的——v8 daemon 读不到 OCR 文本。预检 snapshot 备份后执行
        // 2. FTS5 contentless-external 表的列签名 schema-time 固定，加列必须整表 DROP+CREATE+
        //    重建索引。本机库 <2K 行秒级完成；trigger 同步重写让后续 INSERT/UPDATE 同步索引
        //    extracted_text
        // 3. 跨设备升级窗口：新 daemon 通过 /since 推 extracted_text 字段给老 v8 daemon
        //    （Codable 默认 ignore unknown），老 daemon 静默丢弃。**需要双 Mac 同时升 v9**
        //    才能让 OCR 搜索结果跨设备生效；过渡期老 daemon 看到的对端 image kind 是
        //    text_full=nil 的"空白 OCR"，但 chip 数 / list 不影响
        m.registerMigration("v9_extracted_text") { db in
            // step 1: 加两个新列
            try db.execute(sql: "ALTER TABLE item ADD COLUMN extracted_text TEXT;")
            try db.execute(sql: "ALTER TABLE item ADD COLUMN extracted_text_source TEXT;")

            // step 2: 历史 image kind 数据搬迁——把 text_full 里装的 OCR 文本搬到
            // extracted_text，source 标 'ocr'。条件：kind='image' AND ocr_state='done' AND
            // text_full 非空 AND 非空字符串。`done` 状态保证那段文本确实是 OCR 写入的（
            // pending/skipped/failed 的 image 行 text_full 应该是 nil；不应该有但兜底过滤）
            try db.execute(sql: """
                UPDATE item
                SET extracted_text = text_full,
                    extracted_text_source = 'ocr'
                WHERE kind = 'image'
                  AND ocr_state = 'done'
                  AND text_full IS NOT NULL
                  AND text_full != '';
            """)

            // step 3: image kind 的 text_full 一律清 NULL——新契约"text_full=原始可粘贴文本，
            // image 没有"。这一步也把 step 2 的 done 行清掉，让 image kind 跟其他 kind 在
            // text_full 语义上对齐
            try db.execute(sql: """
                UPDATE item SET text_full = NULL WHERE kind = 'image';
            """)

            // step 4: file kind + image-blob backfill。让 OCRWorker 之后能扫到本机已有的
            // 71 张图片文件（用户从 Finder 复制 .png 进库的）。
            // 条件：本机 own-origin（OCR Phase 1 不变量）AND kind=file AND blob_mime 是
            // image/* AND blob 字节就绪（blob_sha256 非空）AND 未软删 AND 当前 ocr_state 是
            // 老语义下的"未处理"（NULL = capture 时没标 pending 因为不是 image kind）
            try db.execute(sql: """
                UPDATE item
                SET ocr_state = 'pending'
                WHERE kind = 'file'
                  AND blob_mime LIKE 'image/%'
                  AND blob_sha256 IS NOT NULL
                  AND deleted_at_ns IS NULL
                  AND ocr_state IS NULL;
            """)

            // step 5: 整表重建 FTS5 索引——加 extracted_text 进索引列。
            // contentless-external 的列签名 schema-time 固定，没法 ALTER。
            //
            // 顺序：drop 3 个 trigger → drop fts 表 → create 新 fts 表 → rebuild 索引
            // 数据 → 建 3 个新 trigger。这段必须在事务内执行（migration 默认在 tx 内）
            try db.execute(sql: "DROP TRIGGER IF EXISTS item_au;")
            try db.execute(sql: "DROP TRIGGER IF EXISTS item_ad;")
            try db.execute(sql: "DROP TRIGGER IF EXISTS item_ai;")
            try db.execute(sql: "DROP TABLE IF EXISTS item_fts;")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE item_fts USING fts5(
                    text_full,
                    preview,
                    source_app_name,
                    extracted_text,
                    content='item',
                    content_rowid='rowid',
                    tokenize='unicode61 remove_diacritics 2'
                );
            """)
            // 用 `INSERT INTO item_fts(item_fts) VALUES('rebuild')` 触发 contentless-external
            // 模式的全量重建：FTS5 自动从 item 表按 content_rowid 拉每行做 tokenize。
            // 比手动 `INSERT INTO item_fts(rowid, col1, col2...) SELECT ...` 省 SQL 也避免漏列
            try db.execute(sql: "INSERT INTO item_fts(item_fts) VALUES('rebuild');")

            // 3 个 trigger 重建：在 v1 基础上加 extracted_text 这一列
            try db.execute(sql: """
                CREATE TRIGGER item_ai AFTER INSERT ON item BEGIN
                    INSERT INTO item_fts(rowid, text_full, preview, source_app_name, extracted_text)
                    VALUES (new.rowid, new.text_full, new.preview, new.source_app_name, new.extracted_text);
                END;
            """)
            try db.execute(sql: """
                CREATE TRIGGER item_ad AFTER DELETE ON item BEGIN
                    INSERT INTO item_fts(item_fts, rowid, text_full, preview, source_app_name, extracted_text)
                    VALUES ('delete', old.rowid, old.text_full, old.preview, old.source_app_name, old.extracted_text);
                END;
            """)
            try db.execute(sql: """
                CREATE TRIGGER item_au AFTER UPDATE ON item BEGIN
                    INSERT INTO item_fts(item_fts, rowid, text_full, preview, source_app_name, extracted_text)
                    VALUES ('delete', old.rowid, old.text_full, old.preview, old.source_app_name, old.extracted_text);
                    INSERT INTO item_fts(rowid, text_full, preview, source_app_name, extracted_text)
                    VALUES (new.rowid, new.text_full, new.preview, new.source_app_name, new.extracted_text);
                END;
            """)
        }

        m.registerMigration("v10_app_icon") { db in
            // iOS / 远端 client 通过 /app_icon/<bundleID> 拉 PNG 字节。
            // bundleID 作 PK = 多设备各自维护一份(无法天然 dedup,但单机 ~几百 KB 可忽略)。
            // 内容字节由 NSWorkspace.icon 算出 + PNG encode,daemon 端注入 resolver;
            // 缺失 app(用户已卸载)→ resolver 返 nil,本表不写入(每次请求都重 miss 也 OK,
            // 走 nonAppBundleIDs 黑名单或 in-memory negative cache 减压)。
            try db.execute(sql: """
                CREATE TABLE app_icon (
                    bundle_id     TEXT PRIMARY KEY,
                    png_bytes     BLOB NOT NULL,
                    fetched_at_ns INTEGER NOT NULL,
                    app_version   TEXT
                ) STRICT;
            """)
        }

        m.registerMigration("v11_clear_app_icon_for_encoder_fix") { db in
            // 老 encoder 走 image.cgImage(forProposedRect:),会把 NSImage 小 rep
            // (32/64px)的 dock baseline shadow / 倒影烘进字节,iOS 卡片底部一条暗 strip。
            // 新 encoder 直接挑最大 NSBitmapImageRep(1024px 干净 squircle)重绘。
            // 清表让 daemon 重启后第一次 /app_icon/<bid> 自然 re-resolve 写入新字节
            try db.execute(sql: "DELETE FROM app_icon;")
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
        // 用 `+ 1` 不是 `&+ 1`：Int64 ns 在 292 年才溢出（2262 年），溢出 trap 比静默
        // wraparound 回到 ~1970 时间戳要好——后者会让 /since cursor 永久卡死，trap 至少
        // 让 daemon crash 在显眼处便于事后定位
        return Swift.max(now, prev + 1)
    }

    /// 查本机当前 MAX(ingested_at_ns)，0 表示空表。WS hello + cursor_advanced 用——
    /// peer 收到后跟自己 cursor 比，决定是否立即拉一页（无论是否在原本 30s tick 周期）。
    /// 包装成 Database 方法是因为 broadcaster 不该直接看 GRDB 抽象。
    public func currentMaxIngestedNs() async throws -> Int64 {
        try await pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(ingested_at_ns) FROM item") ?? 0
        }
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

    /// 数 blob_sha256 = sha 且未软删的 item 行。磁盘水位驱逐前用：refCount > 1 时
    /// 删盘也只清一个 sha 的字节（同 sha 多行共用），所以这里只关心 sha 是否仍被任何
    /// 活跃行引用。tombstone (`deleted_at_ns IS NOT NULL`) 不算 ref——那些行本来就
    /// 可以 blob GC。
    public func refCountForBlob(sha256: String) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM item
                WHERE blob_sha256 = ? AND deleted_at_ns IS NULL
            """, arguments: [sha256]) ?? 0
        }
    }

    /// 按 `MIN(deleted_at_ns) ASC` 列出"孤儿 blob"—— 所有引用行都已 tombstone
    /// 的 sha。空间压力下应**优先**驱逐这些（strictly 优于 LRU），因为：
    /// - 没有任何活跃行需要这些字节
    /// - 用户搜索 / UI 永远看不到对应行（已软删）
    /// - 不触发 CloudBadge 云端态切换（没行可显示）
    ///
    /// 过滤：sha 上的**所有**ref 行 `deleted_at_ns IS NOT NULL`。换言之只要有一行还活
    /// 着，这个 sha 就不在候选——它仍是 [[oldest-evictable-shas]] 路径的目标。
    ///
    /// 排序：`MIN(deleted_at_ns) ASC`——最早被软删的最先驱逐。语义"过期墓碑先清"。
    ///
    /// 返回 `(sha, blobSize)` 让 caller 累计字节量；blob_size 是 capture 时记的逻辑值。
    public func tombstoneEvictableShas(
        limit: Int, offset: Int = 0
    ) throws -> [(sha: String, blobSize: Int64)] {
        precondition(limit > 0, "limit must be > 0")
        precondition(offset >= 0, "offset must be >= 0")
        return try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT blob_sha256 AS sha,
                       COALESCE(MAX(blob_size), 0) AS sz,
                       MIN(deleted_at_ns) AS oldest_tomb
                FROM item
                WHERE blob_sha256 IS NOT NULL
                GROUP BY blob_sha256
                HAVING SUM(CASE WHEN deleted_at_ns IS NULL THEN 1 ELSE 0 END) = 0
                ORDER BY oldest_tomb ASC
                LIMIT ? OFFSET ?
            """, arguments: [limit, offset]).map {
                (sha: $0["sha"] as String, blobSize: $0["sz"] as Int64)
            }
        }
    }

    /// 按 `captured_at_ns ASC` 列出可驱逐的 blob sha——最老优先。
    ///
    /// 过滤契约（缺一不可，少了任何一条都会出事）：
    /// - `blob_sha256 IS NOT NULL` —— text-kind 行没 blob 可驱逐
    /// - `deleted_at_ns IS NULL` —— tombstone 走 [[tombstone-evictable-shas]] 单独路径
    /// - `pinned = 0` —— **用户钉的永不驱逐**（硬不变量，不要回退）
    ///
    /// 同 sha 多行只算一次（`MIN(captured_at_ns)` 决定排序键）——驱逐删的是 sha 字节，
    /// 重复返回同 sha 浪费循环。
    ///
    /// 返回 `(sha, blobSize)` 让 caller 累计驱逐字节量决定是否够腾水位，不用每次都
    /// 读 fs。**blob_size 是 DB 里 capture 时记的逻辑大小**，不代表 BlobStore fs 上的
    /// 物理大小（极端情况下可能小几个 byte），但水位决策不需要那么精确。
    public func oldestEvictableShas(limit: Int) throws -> [(sha: String, blobSize: Int64)] {
        precondition(limit > 0, "limit must be > 0")
        return try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT blob_sha256 AS sha,
                       COALESCE(MAX(blob_size), 0) AS sz,
                       MIN(captured_at_ns) AS oldest
                FROM item
                WHERE blob_sha256 IS NOT NULL
                  AND deleted_at_ns IS NULL
                  AND pinned = 0
                GROUP BY blob_sha256
                ORDER BY oldest ASC
                LIMIT ?
            """, arguments: [limit]).map {
                (sha: $0["sha"] as String, blobSize: $0["sz"] as Int64)
            }
        }
    }

    /// 一键 WAL checkpoint，用于 snapshot 前刷盘
    public func checkpoint() throws {
        _ = try pool.writeWithoutTransaction { db in
            try db.checkpoint(.truncate)
        }
    }

    /// 把单行 `captured_at_ns` 顶到 `now`(或 max+1 单增兜底)+ bump `ingested_at_ns` 让
    /// /since cursor 推进让对端通过 PullWorker 看到这条变化。**不动 `origin_device`**——
    /// 顶是时间属性变化,不是归属变化(剪贴板心智:任意 peer 都能把任意 origin 的行顶上去)。
    ///
    /// 用途:跨设备一致的"复制即顶"。iOS tap 自己历史里的某条 → POST /bump/<id> →
    /// Mac handler 调本函数。Mac 端 capture(原始路径)走 ingestText/Blob 的 merge 分支也
    /// 自然 bump,这里是给"非 capture 触发"路径用的独立入口。
    ///
    /// 不变量:
    /// - **writer tx 内调 nextIngestNs**(同 ingestText/Blob 路径)——保 /since cursor 单增
    /// - tombstone (deleted_at_ns 非 nil) 拒 bump,抛 `.deleted`
    /// - 不存在的 id 抛 `.notFound`
    /// - captured_at_ns 用 max(now, prev+1) 避免回退(now 来自 wall clock 可能漂移)
    public func bumpCapturedAt(id: String, now: Int64) async throws -> Int64 {
        try await pool.write { db in
            guard let row = try Item.filter(Column("id") == id).fetchOne(db) else {
                throw BumpError.notFound
            }
            if row.deletedAtNs != nil {
                throw BumpError.deleted
            }
            let newCap = Swift.max(now, row.capturedAtNs &+ 1)
            let newIngest = try Self.nextIngestNs(db, now: now)
            try db.execute(sql: """
                UPDATE item
                SET captured_at_ns = ?, ingested_at_ns = ?
                WHERE id = ?
            """, arguments: [newCap, newIngest, id])
            return newIngest
        }
    }

    /// 软删:写 `deleted_at_ns = now` + bump `ingested_at_ns` 让对端通过 PullWorker
    /// 看到 tombstone。**不动 captured_at_ns / origin_device / 内容字段**——删是元数据
    /// 变化,不是归属变化(任意 peer 都能删任意 origin 的行)。
    ///
    /// 用途:iOS 长按"删除" → DELETE /item/<id> → handler 调本函数;Mac UI ⌘Backspace /
    /// contextMenu 走 AppState.deleteItem;CLI admin-soft-delete 通过 HTTP DELETE 兜底。
    ///
    /// **Cascade**(plan hashed-allen §C):`cascade=true` 且目标是 text-kind
    /// (`blob_sha256 IS NULL && text_full 非空`) → 把同 text_full 所有 active sibling
    /// 一起 tombstone(跨 origin)。理由:mesh 拓扑下 cross-device 副本进 mirror,
    /// 两台 Mac 行集合对称,只删单 id 会让 mirror 兄弟存活 → UI fold 仍能看到。
    /// blob-kind / cascade=false → 退化为只删单 id。
    ///
    /// 不变量:
    /// - **writer tx 内调 nextIngestNs**——每个 sibling 单独 stamp 严格单增
    /// - 目标不存在抛 `.notFound`,目标已 tombstone 抛 `.alreadyDeleted`
    /// - sibling 已 tombstone / 不再匹配 text_full / blob_sha256 非空 → stderr warn 跳过
    ///   (不抛——cascade 是机会主义清理,某条不匹配不该让整批失败)
    /// - 返回 `[(id, newIngest)]` 让调用方算 max(ingestedAtNs) 喂 broadcaster
    public func softDelete(
        id: String,
        now: Int64,
        cascade: Bool = true
    ) async throws -> [(id: String, ingestedAtNs: Int64)] {
        try await pool.write { db in
            guard let target = try Item.filter(Column("id") == id).fetchOne(db) else {
                throw BumpError.notFound
            }
            if target.deletedAtNs != nil {
                throw BumpError.alreadyDeleted
            }

            // 决定 cascade 范围:目标自己永远在;text-kind + cascade=true 时 SELECT 其他
            // active sibling 同 text_full 的 id 加进来
            var siblingIDs: [String] = [id]
            let isTextKind = target.blobSha256 == nil
                && (target.textFull?.isEmpty == false)
            if cascade, isTextKind, let text = target.textFull {
                let otherIDs = try String.fetchAll(db, sql: """
                    SELECT id FROM item
                    WHERE text_full = ? AND blob_sha256 IS NULL
                      AND deleted_at_ns IS NULL AND id != ?
                """, arguments: [text, id])
                siblingIDs.append(contentsOf: otherIDs)
            }

            var results: [(id: String, ingestedAtNs: Int64)] = []
            for sid in siblingIDs {
                // sibling explicit assertion(target 本身已经在前面校验过 active +
                // 是 text-kind,这里只校 sibling 防 race 中状态翻转)
                if sid != id {
                    guard let s = try Item.filter(Column("id") == sid).fetchOne(db) else {
                        continue
                    }
                    if s.deletedAtNs != nil { continue }
                    if s.blobSha256 != nil || s.textFull != target.textFull {
                        FileHandle.standardError.write(Data(
                            "softDelete: skip sibling \(sid) — text_full mismatch or blob-kind\n".utf8
                        ))
                        continue
                    }
                }
                let newIngest = try Self.nextIngestNs(db, now: now)
                try db.execute(sql: """
                    UPDATE item
                    SET deleted_at_ns = ?, ingested_at_ns = ?
                    WHERE id = ?
                """, arguments: [now, newIngest, sid])
                results.append((id: sid, ingestedAtNs: newIngest))
            }
            return results
        }
    }

    /// 读单行 `pinned` 真值。
    ///
    /// **现状无生产调用方**——历史上给 `AppState.togglePin` 在 Task 内重算 target 用
    /// (防快速双击 stale UI snapshot 倒转),后来 togglePin 改走原子 [togglePinAny]
    /// (单 writer tx 内 read+flip+write,关 TOCTOU race),本函数不再被生产代码引用。
    /// 留作公开 API:可独立用于只读 pin 状态查询(诊断 / 测试 / future 需要细粒度
    /// pin 状态检查时直接复用,无需为查询单独打 SQL)。
    ///
    /// Returns:
    /// - 行存在且未 tombstone → 真实 pinned 值
    /// - 行不存在 → 抛 `BumpError.notFound`(调用方应当 silently 视作 race 已发生不再操作)
    /// - 行已 tombstone → 抛 `BumpError.deleted`(同上)
    ///
    /// 跟 setPinnedAny 共享 BumpError 错误集合,catch 路径同 setPinnedAny 一致。
    public func getPinned(id: String) async throws -> Bool {
        try await pool.read { db in
            guard let row = try Item.filter(Column("id") == id).fetchOne(db) else {
                throw BumpError.notFound
            }
            if row.deletedAtNs != nil {
                throw BumpError.deleted
            }
            return row.pinned
        }
    }

    /// 跨 origin 版 setPinned——给 `POST /pin/<id>` HTTP handler 用(HTTP 语义是
    /// "set 绝对值",iOS / 远端调用方明确传 `pinned=true/false`)。**Mac 进程内 UI**
    /// 走独立的 [togglePinAny](单 writer tx 原子 read+flip+write),跟 HTTP 路径职责
    /// 分清——本函数保留给"已知目标值"语义的调用方,不适合做 UI 的 read-modify-write
    /// (两步走在并发场景有 TOCTOU race,详见 [togglePinAny] doc)。
    ///
    /// **不带** own-origin guard,跟 `bumpCapturedAt`/`softDelete` 心智一致(任意 peer
    /// 改任意 origin 行)。理由:mesh 拓扑下 mirror 行占多数(iOS 100%,多 Mac peer 也
    /// 大头是另一台的 mirror),强制 own-origin 等于 UI 上 90%+ 卡不可 pin。严格
    /// own-origin 语义历史上由独立 `setPinned` 函数提供,已删,future 需要可通过加
    /// `requireOwnOrigin: Bool` 参数恢复。
    ///
    /// 已知 limitation:
    /// 1. 本机 mirror 行 pin 后,**对端 origin 设备**不会收到回传——PullWorker.applyPage
    ///    跳过自家 origin 的行(`origin_device == self → continue`)
    /// 2. **其他 mirror peer** 会通过 /since 看到 pin 状态,本机 fold-aware 搜索 `pinned OR
    ///    聚合` 让"内容 pinned"语义在本机 + 其他 mirror peer 自然成立。**但**:`applyPage`
    ///    走 INSERT OR REPLACE 全列覆盖(包括 pinned 列),一旦 origin 设备后续对该 row 做
    ///    任何 bump `ingested_at_ns` 的操作(POST /bump = bumpCapturedAt / 文本永久 dedup
    ///    merge bump / OCR markDone 回放 / softDelete tombstone 等),origin 视角下
    ///    pinned=false 会带新 ingested_at_ns 通过 /since 推到其他 mirror peer,触发整行覆盖
    ///    把跨 origin 打的 pin 静默抹掉。用户感知 = "我置顶的某条几小时后自己掉下去了"
    /// 3. origin 设备本地仍看到非 pinned(同 #1)
    ///
    /// 真正双向回传 + 字段级 OR-merge(pinned 列不被回放覆盖)要等 `/update` 路由(本函数即
    /// 雏形)。中期 mitigation 选项:applyPage 对 pinned 列走 take-max/OR-merge 而非 REPLACE。
    ///
    /// **注意**:OR-merge 让 unpin 操作无法跨 mirror peer 传播(本机 unpin=false 会被对端
    /// pinned=true 吃掉),要么接受这个 trade-off,要么等 `/update` 路由做真正的字段级
    /// last-writer-wins。
    ///
    /// 不变量:
    /// - **writer tx 内调 nextIngestNs**——保 /since cursor 单增
    /// - tombstone (deleted_at_ns 非 nil) 拒 pin,抛 `.deleted`
    /// - 不存在的 id 抛 `.notFound`
    /// - 已是目标状态 = noop 不 bump cursor,返回 nil(handler 当 200 OK 处理)。**不**抛
    ///   `.alreadyPinned` 这种独立 error —— pin 是幂等切换,"已是目标"语义跟 `bumpCapturedAt`
    ///   的"id 还存在"一样自然,跟 `softDelete.alreadyDeleted` 不同(那里是"二次删除"明确异常)
    /// - **不动 captured_at_ns / origin_device**:pin 是元数据切换不是顺序变化。跟
    ///   `bumpCapturedAt`(改 captured_at_ns)/`softDelete`(写 deleted_at_ns)区别:这俩
    ///   会让对端列表重排,pin 让对端通过 `pinned DESC` 排序自然 promote(captured_at_ns
    ///   保留原值,unpin 后回到原位置不变)
    ///
    /// Returns: 新 ingested_at_ns；已是目标状态时返 nil（不 bump cursor 防止退化成无意义 fan-out）
    public func setPinnedAny(id: String, pinned: Bool, now: Int64) async throws -> Int64? {
        try await pool.write { db in
            guard let row = try Item.filter(Column("id") == id).fetchOne(db) else {
                throw BumpError.notFound
            }
            if row.deletedAtNs != nil {
                throw BumpError.deleted
            }
            if row.pinned == pinned { return nil }
            let newIngest = try Self.nextIngestNs(db, now: now)
            try db.execute(sql: """
                UPDATE item
                SET pinned = ?, ingested_at_ns = ?
                WHERE id = ?
            """, arguments: [pinned ? 1 : 0, newIngest, id])
            return newIngest
        }
    }

    /// 原子 toggle item.pinned——在**单一 writer tx** 内 read → flip → write,
    /// 关闭 [getPinned] + [setPinnedAny] 两步走的 TOCTOU race window:
    /// 旧两步实现下并发 ⌘P 两 Task 都能在 A commit 前 reader-snapshot 看到 pinned=false →
    /// 都算 target=true → A 写 true / B noop → 净翻一次。本函数让 toggle 在 writer tx
    /// 内完成,GRDB 串行 writer queue 天然 race-free。
    ///
    /// 跨 origin 生效(同 [setPinnedAny] 哲学):不带 own-origin guard,本机 mirror 行也能翻。
    /// 同款 limitation 也适用——本机翻 mirror 行不回传 origin 设备 + origin 后续 bump
    /// 通过 INSERT OR REPLACE 抹掉跨 origin pin。详见 setPinnedAny doc。
    ///
    /// 不变量:
    /// - **writer tx 内调 nextIngestNs**——保 /since cursor 单增
    /// - tombstone (deleted_at_ns 非 nil) 拒 toggle,抛 `.deleted`
    /// - 不存在的 id 抛 `.notFound`
    /// - **不动 captured_at_ns / origin_device**:pin 是元数据切换不是顺序变化
    ///
    /// Returns: `(newPinned, newIngestNs)`——newPinned 是翻**后**的值,调用方用来 fan-out
    /// 给对端推 cursor_advanced。**永远不返 nil**(getPinned + setPinnedAny 那种"已是目标"
    /// noop 在 toggle 语义下不可能发生——每次 toggle 都翻反)
    public func togglePinAny(id: String, now: Int64) async throws -> (newPinned: Bool, newIngest: Int64) {
        try await pool.write { db in
            guard let row = try Item.filter(Column("id") == id).fetchOne(db) else {
                throw BumpError.notFound
            }
            if row.deletedAtNs != nil {
                throw BumpError.deleted
            }
            let newPinned = !row.pinned
            let newIngest = try Self.nextIngestNs(db, now: now)
            try db.execute(sql: """
                UPDATE item
                SET pinned = ?, ingested_at_ns = ?
                WHERE id = ?
            """, arguments: [newPinned ? 1 : 0, newIngest, id])
            return (newPinned, newIngest)
        }
    }
}

public enum BumpError: Error, Equatable {
    case notFound
    case deleted
    /// softDelete 专用——目标行已是 tombstone,handler 映射 410 → iOS 当幂等成功
    case alreadyDeleted
}
