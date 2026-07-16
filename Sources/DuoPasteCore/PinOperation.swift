import Foundation
import GRDB

/// 非 owner 设备持久化的 pin/unpin 绝对值命令。每个 item 同时只保留最新一条 active intent。
public struct PinOperation: Sendable, Equatable, Codable {
    public enum State: String, Sendable, Codable {
        case pending
        case awaitingReplay = "awaiting_replay"
    }

    public let operationID: String
    public let itemID: String
    public let originDevice: String
    public let desiredPinned: Bool
    public let state: State
    public let ownerIngestedAtNs: Int64?
    public let createdAtNs: Int64
    public let updatedAtNs: Int64
    public let attemptCount: Int
    public let lastError: String?

    public init(
        operationID: String,
        itemID: String,
        originDevice: String,
        desiredPinned: Bool,
        state: State = .pending,
        ownerIngestedAtNs: Int64? = nil,
        createdAtNs: Int64,
        updatedAtNs: Int64,
        attemptCount: Int = 0,
        lastError: String? = nil
    ) {
        self.operationID = operationID
        self.itemID = itemID
        self.originDevice = originDevice
        self.desiredPinned = desiredPinned
        self.state = state
        self.ownerIngestedAtNs = ownerIngestedAtNs
        self.createdAtNs = createdAtNs
        self.updatedAtNs = updatedAtNs
        self.attemptCount = attemptCount
        self.lastError = lastError
    }
}

public enum PinSubmitResult: Sendable, Equatable {
    /// owner 已 canonical apply；duplicate=true 表示命中同 operation_id 的 receipt。
    case applied(operationID: String, ingestedAtNs: Int64, duplicate: Bool)
    /// 当前设备不是 owner：已乐观更新本地行并把命令持久化等待投递。
    case pending(PinOperation)
}

public enum PinOperationError: Error, Sendable, Equatable {
    case invalidOperationID
    case operationIDConflict
}

extension Database {
    /// 提交一个带稳定 operation ID 的 pin/unpin 绝对值意图。
    ///
    /// - owner 本机：在 writer tx 内 canonical apply + bump cursor + 写 receipt。
    /// - 非 owner：只乐观改本机 `pinned`（不 bump cursor，避免 mirror 整行冒充 canonical）并
    ///   写 `pin_operation`；PullWorker 之后按 origin route。
    public func submitPinIntent(
        id: String,
        pinned: Bool,
        operationID: String,
        selfDeviceID: String,
        now: Int64
    ) async throws -> PinSubmitResult {
        guard !operationID.isEmpty, operationID.utf8.count <= 128 else {
            throw PinOperationError.invalidOperationID
        }
        return try await pool.write { db in
            try Self.submitPinIntent(
                db,
                id: id,
                pinned: pinned,
                operationID: operationID,
                selfDeviceID: selfDeviceID,
                now: now
            )
        }
    }

    /// Mac UI 的原子 toggle：在同一个 writer tx 内读取当前（含 optimistic）状态、翻转并
    /// 提交 owner-routed intent，保留旧 `togglePinAny` 的快速连按 race-free 契约。
    public func togglePinIntent(
        id: String,
        operationID: String,
        selfDeviceID: String,
        now: Int64
    ) async throws -> (pinned: Bool, result: PinSubmitResult) {
        guard !operationID.isEmpty, operationID.utf8.count <= 128 else {
            throw PinOperationError.invalidOperationID
        }
        return try await pool.write { db in
            guard let item = try Item.filter(Column("id") == id).fetchOne(db) else {
                throw BumpError.notFound
            }
            if item.deletedAtNs != nil { throw BumpError.deleted }
            let desired = !item.pinned
            let result = try Self.submitPinIntent(
                db,
                id: id,
                pinned: desired,
                operationID: operationID,
                selfDeviceID: selfDeviceID,
                now: now
            )
            return (desired, result)
        }
    }

    /// 某个 PullWorker 只取属于其 peer device ID 的 pending command。
    public func pendingPinOperations(originDevice: String, limit: Int = 50) async throws -> [PinOperation] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM pin_operation
                WHERE origin_device = ? AND state = 'pending'
                ORDER BY created_at_ns ASC
                LIMIT ?
            """, arguments: [originDevice, max(1, min(limit, 500))])
            return rows.compactMap(Self.decodePinOperation)
        }
    }

    /// owner 返回 receipt 后进入 awaiting replay；只有 `/since` 真看到 canonical 行才清 UI pending。
    public func markPinOperationDelivered(
        operationID: String,
        ownerIngestedAtNs: Int64,
        now: Int64
    ) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                UPDATE pin_operation
                SET state = 'awaiting_replay', owner_ingested_at_ns = ?,
                    updated_at_ns = ?, attempt_count = attempt_count + 1, last_error = NULL
                WHERE operation_id = ?
            """, arguments: [ownerIngestedAtNs, now, operationID])
        }
    }

    public func markPinOperationFailed(operationID: String, reason: String, now: Int64) async throws {
        let bounded = String(reason.prefix(1_000))
        try await pool.write { db in
            try db.execute(sql: """
                UPDATE pin_operation
                SET updated_at_ns = ?, attempt_count = attempt_count + 1, last_error = ?
                WHERE operation_id = ?
            """, arguments: [now, bounded, operationID])
        }
    }

    public func discardPinOperation(operationID: String) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "DELETE FROM pin_operation WHERE operation_id = ?",
                arguments: [operationID]
            )
        }
    }

    public func pendingPinItemIDs() async throws -> Set<String> {
        try await pool.read { db in
            Set(try String.fetchAll(db, sql: "SELECT item_id FROM pin_operation"))
        }
    }

    /// PullWorker 的 writer tx 内调用：让 canonical replay 在 pending window 里不会先把
    /// optimistic UI 覆盖回旧值。
    public static func activePinOperation(_ db: GRDB.Database, itemID: String) throws -> PinOperation? {
        let row = try Row.fetchOne(db, sql: "SELECT * FROM pin_operation WHERE item_id = ?", arguments: [itemID])
        return row.flatMap(decodePinOperation)
    }

    /// incoming owner 行达到 receipt cursor 且状态等于目标时，记录本机 convergence receipt
    /// 并删 active queue。之后 iOS 用同 operation ID 重试，本 peer 也能返回 applied。
    public static func resolvePinOperationReplayIfNeeded(
        _ db: GRDB.Database,
        operation: PinOperation?,
        incoming: Item,
        now: Int64
    ) throws -> Bool {
        guard let operation,
              operation.state == .awaitingReplay,
              incoming.originDevice == operation.originDevice,
              incoming.pinned == operation.desiredPinned,
              let incomingNs = incoming.ingestedAtNs,
              let expectedNs = operation.ownerIngestedAtNs,
              incomingNs >= expectedNs
        else { return false }
        try insertPinReceipt(
            db,
            operationID: operation.operationID,
            itemID: operation.itemID,
            desiredPinned: operation.desiredPinned,
            appliedIngestedAtNs: expectedNs,
            now: now
        )
        try db.execute(
            sql: "DELETE FROM pin_operation WHERE operation_id = ?",
            arguments: [operation.operationID]
        )
        return true
    }

    private struct PinReceipt {
        let itemID: String
        let desiredPinned: Bool
        let appliedIngestedAtNs: Int64
    }

    private static func submitPinIntent(
        _ db: GRDB.Database,
        id: String,
        pinned: Bool,
        operationID: String,
        selfDeviceID: String,
        now: Int64
    ) throws -> PinSubmitResult {
        if let receipt = try fetchPinReceipt(db, operationID: operationID) {
            guard receipt.itemID == id, receipt.desiredPinned == pinned else {
                throw PinOperationError.operationIDConflict
            }
            return .applied(
                operationID: operationID,
                ingestedAtNs: receipt.appliedIngestedAtNs,
                duplicate: true
            )
        }
        if let existing = try fetchPinOperation(db, operationID: operationID) {
            guard existing.itemID == id, existing.desiredPinned == pinned else {
                throw PinOperationError.operationIDConflict
            }
            return .pending(existing)
        }

        guard let item = try Item.filter(Column("id") == id).fetchOne(db) else {
            throw BumpError.notFound
        }
        if item.deletedAtNs != nil { throw BumpError.deleted }

        if item.originDevice == selfDeviceID {
            // 首次命令即使 pinned 已等于目标也 bump：requester 的 cursor 可能已经越过
            // 当前行；制造一个新的 canonical replay 才能让 awaiting 状态确定收敛。
            let newIngest = try nextIngestNs(db, now: now)
            try db.execute(sql: """
                UPDATE item SET pinned = ?, ingested_at_ns = ? WHERE id = ?
            """, arguments: [pinned ? 1 : 0, newIngest, id])
            try insertPinReceipt(
                db,
                operationID: operationID,
                itemID: id,
                desiredPinned: pinned,
                appliedIngestedAtNs: newIngest,
                now: now
            )
            return .applied(
                operationID: operationID,
                ingestedAtNs: newIngest,
                duplicate: false
            )
        }

        // 最终意图 wins：同 item 旧 active command 不再投递。HTTP / Mac UI 都串行发
        // 绝对值，in-flight 旧命令即使已到 owner，新命令随后仍会把 canonical 状态纠正。
        try db.execute(sql: "DELETE FROM pin_operation WHERE item_id = ?", arguments: [id])
        try db.execute(sql: "UPDATE item SET pinned = ? WHERE id = ?", arguments: [pinned ? 1 : 0, id])
        try db.execute(sql: """
            INSERT INTO pin_operation
              (operation_id, item_id, origin_device, desired_pinned, state,
               owner_ingested_at_ns, created_at_ns, updated_at_ns,
               attempt_count, last_error)
            VALUES (?, ?, ?, ?, 'pending', NULL, ?, ?, 0, NULL)
        """, arguments: [operationID, id, item.originDevice, pinned ? 1 : 0, now, now])
        return .pending(PinOperation(
            operationID: operationID,
            itemID: id,
            originDevice: item.originDevice,
            desiredPinned: pinned,
            createdAtNs: now,
            updatedAtNs: now
        ))
    }

    private static func fetchPinReceipt(_ db: GRDB.Database, operationID: String) throws -> PinReceipt? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT item_id, desired_pinned, applied_ingested_at_ns
            FROM pin_operation_receipt WHERE operation_id = ?
        """, arguments: [operationID]) else { return nil }
        return PinReceipt(
            itemID: row["item_id"],
            desiredPinned: (row["desired_pinned"] as Int) != 0,
            appliedIngestedAtNs: row["applied_ingested_at_ns"]
        )
    }

    private static func fetchPinOperation(_ db: GRDB.Database, operationID: String) throws -> PinOperation? {
        let row = try Row.fetchOne(db, sql: "SELECT * FROM pin_operation WHERE operation_id = ?", arguments: [operationID])
        return row.flatMap(decodePinOperation)
    }

    private static func decodePinOperation(_ row: Row) -> PinOperation? {
        guard let operationID: String = row["operation_id"],
              let itemID: String = row["item_id"],
              let originDevice: String = row["origin_device"],
              let stateRaw: String = row["state"],
              let state = PinOperation.State(rawValue: stateRaw)
        else { return nil }
        let desired: Int = row["desired_pinned"] ?? 0
        return PinOperation(
            operationID: operationID,
            itemID: itemID,
            originDevice: originDevice,
            desiredPinned: desired != 0,
            state: state,
            ownerIngestedAtNs: row["owner_ingested_at_ns"],
            createdAtNs: row["created_at_ns"] ?? 0,
            updatedAtNs: row["updated_at_ns"] ?? 0,
            attemptCount: row["attempt_count"] ?? 0,
            lastError: row["last_error"]
        )
    }

    private static func insertPinReceipt(
        _ db: GRDB.Database,
        operationID: String,
        itemID: String,
        desiredPinned: Bool,
        appliedIngestedAtNs: Int64,
        now: Int64
    ) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO pin_operation_receipt
              (operation_id, item_id, desired_pinned, applied_ingested_at_ns, applied_at_ns)
            VALUES (?, ?, ?, ?, ?)
        """, arguments: [operationID, itemID, desiredPinned ? 1 : 0, appliedIngestedAtNs, now])
        // receipt 只需覆盖实际离线/网络重试窗口；90 天后同一绝对值再次执行仍不会翻错，
        // 只会制造一次无害 canonical replay。这样长期 daily-driver 不会无限长表。
        let retentionNs: Int64 = 90 * 24 * 60 * 60 * 1_000_000_000
        try db.execute(
            sql: "DELETE FROM pin_operation_receipt WHERE applied_at_ns < ?",
            arguments: [now - retentionNs]
        )
    }
}
