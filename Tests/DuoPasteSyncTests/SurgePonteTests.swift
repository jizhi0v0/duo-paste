import Foundation
import Testing
@testable import DuoPasteSync

@Suite("SurgePonte self-hostname discovery")
struct SurgePonteTests {
    // MARK: - 算法 happy path

    @Test func exactMatchSingleEntryHits() {
        // 真实场景：mini = (Mac16,10, "Bobby's Mac mini")，列表里另有 AppleTV (type=4)
        // + MBP (model 不同)。期望挑出 mini 这条并 lowercase.
        let list: [[String: Any]] = [
            applePonteEntry(name: "Bobby's AppleTV", model: "AppleTV14,1", ponteName: "TV-2287", type: 4),
            applePonteEntry(name: "Bobby's Mac mini", model: "Mac16,10", ponteName: "MAC", type: 3),
            applePonteEntry(name: "Bobby's MacBook Pro", model: "Mac15,11", ponteName: "MBPMBP", type: 3),
        ]
        let host = SurgePonte.matchSelf(
            in: list,
            hwModel: "Mac16,10",
            computerName: "Bobby's Mac mini"
        )
        #expect(host == "mac.sgponte")
    }

    @Test func lowercasesPonteNameWhenBuildingHostname() {
        let list = [applePonteEntry(name: "MBP", model: "Mac15,11", ponteName: "MBPMBP", type: 3)]
        let host = SurgePonte.matchSelf(in: list, hwModel: "Mac15,11", computerName: "MBP")
        #expect(host == "mbpmbp.sgponte")
    }

    // MARK: - ponteType 过滤

    @Test func ignoresEntriesWithNonActivePonteType() {
        // AppleTV (type=4) 不算 Ponte device，即便 model/name 都对也跳过。
        let list = [applePonteEntry(name: "ATV", model: "AppleTV14,1", ponteName: "TV", type: 4)]
        let host = SurgePonte.matchSelf(in: list, hwModel: "AppleTV14,1", computerName: "ATV")
        #expect(host == nil)
    }

    @Test func ignoresEntriesMissingPonteType() {
        // 万一 plist 缺字段，当不匹配处理，不崩。
        var entry = applePonteEntry(name: "X", model: "Mac16,10", ponteName: "MAC", type: 3)
        if var p = entry["ponteParameter"] as? [String: Any] {
            p.removeValue(forKey: "ponteType")
            entry["ponteParameter"] = p
        }
        let host = SurgePonte.matchSelf(in: [entry], hwModel: "Mac16,10", computerName: "X")
        #expect(host == nil)
    }

    // MARK: - 多条同名同型号 → 放弃

    @Test func multipleExactMatchesGivesUp() {
        // 两条 (model=Mac16,10, name="X")，无法区分——按 spec 放弃返回 nil
        let list = [
            applePonteEntry(name: "X", model: "Mac16,10", ponteName: "A", type: 3),
            applePonteEntry(name: "X", model: "Mac16,10", ponteName: "B", type: 3),
        ]
        let host = SurgePonte.matchSelf(in: list, hwModel: "Mac16,10", computerName: "X")
        #expect(host == nil)
    }

    // MARK: - fallback：精确 0 条 → 单 model 命中

    @Test func fallbackToModelOnlyWhenNameDoesNotMatch() {
        // 用户重命名了 ComputerName 后 Surge 那条 deviceName 滞后；按 model 唯一命中也 OK
        let list = [
            applePonteEntry(name: "Mini OLD", model: "Mac16,10", ponteName: "MAC", type: 3),
            applePonteEntry(name: "MBP", model: "Mac15,11", ponteName: "MBPMBP", type: 3),
        ]
        let host = SurgePonte.matchSelf(
            in: list,
            hwModel: "Mac16,10",
            computerName: "Bobby's Mac mini" // 跟 plist 的 "Mini OLD" 对不上
        )
        #expect(host == "mac.sgponte")
    }

    @Test func fallbackRejectsMultipleSameModel() {
        // 两台同型号（Studio 双机房）—— fallback 也无法区分，放弃
        let list = [
            applePonteEntry(name: "MBP-1", model: "Mac15,11", ponteName: "MBP1", type: 3),
            applePonteEntry(name: "MBP-2", model: "Mac15,11", ponteName: "MBP2", type: 3),
        ]
        let host = SurgePonte.matchSelf(in: list, hwModel: "Mac15,11", computerName: "Other")
        #expect(host == nil)
    }

    @Test func fallbackRejectsWhenNoModelMatch() {
        // Surge 没记本机 → 既不精确命中也没 model 候选 → nil
        let list = [applePonteEntry(name: "MBP", model: "Mac15,11", ponteName: "MBPMBP", type: 3)]
        let host = SurgePonte.matchSelf(in: list, hwModel: "Mac16,10", computerName: "Other")
        #expect(host == nil)
    }

    // MARK: - 边界

    @Test func emptyListReturnsNil() {
        let host = SurgePonte.matchSelf(in: [], hwModel: "Mac16,10", computerName: "X")
        #expect(host == nil)
    }

    @Test func emptyOrWhitespacePonteNameReturnsNil() {
        // 别拼出 ".sgponte" 这种残品
        let list = [applePonteEntry(name: "X", model: "Mac16,10", ponteName: "   ", type: 3)]
        let host = SurgePonte.matchSelf(in: list, hwModel: "Mac16,10", computerName: "X")
        #expect(host == nil)
    }

    @Test func exactMatchPreferredOverFallback() {
        // 精确匹配存在时不该走 fallback。这里 model 有两条但只有一条 name 也对——必须 hit 这条
        let list = [
            applePonteEntry(name: "Mini A", model: "Mac16,10", ponteName: "MAC-A", type: 3),
            applePonteEntry(name: "Mini B", model: "Mac16,10", ponteName: "MAC-B", type: 3),
        ]
        let host = SurgePonte.matchSelf(in: list, hwModel: "Mac16,10", computerName: "Mini B")
        #expect(host == "mac-b.sgponte")
    }

    // MARK: - plist 装载

    @Test func loadPonteDeviceListReadsArrayFromRealPlistFormat() throws {
        // 写一个 mini plist 到 tmp，确保 PropertyListSerialization 路径 OK
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/SGCore.plist"
        let root: [String: Any] = [
            "PonteDeviceList": [
                applePonteEntry(name: "X", model: "Mac16,10", ponteName: "MAC", type: 3) as [String: Any]
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try data.write(to: URL(fileURLWithPath: path))

        let arr = try SurgePonte.loadPonteDeviceList(at: path)
        #expect(arr.count == 1)
        #expect(arr[0]["deviceName"] as? String == "X")
    }

    @Test func loadPonteDeviceListThrowsWhenFileMissing() {
        #expect(throws: (any Error).self) {
            _ = try SurgePonte.loadPonteDeviceList(at: "/nonexistent/SGCore.plist")
        }
    }

    @Test func discoverReturnsNilWhenPlistMissing() {
        // discoverSelfHostname graceful——没装 Surge 是合法状态
        let host = SurgePonte.discoverSelfHostname(
            plistPath: "/nonexistent/SGCore.plist",
            hwModel: "Mac16,10",
            computerName: "X"
        )
        #expect(host == nil)
    }

    // MARK: - helpers

    private func applePonteEntry(name: String, model: String, ponteName: String, type: Int) -> [String: Any] {
        return [
            "deviceName": name,
            "ponteName": ponteName,
            "ponteParameter": [
                "deviceModel": model,
                "ponteType": type,
            ] as [String: Any],
        ]
    }

    private func makeTempDir() throws -> String {
        let path = NSTemporaryDirectory() + "surge-ponte-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
}
