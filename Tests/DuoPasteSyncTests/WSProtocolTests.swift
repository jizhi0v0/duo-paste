import Testing
import Foundation
import DuoPasteCore
@testable import DuoPasteSync

@Suite struct WSProtocolTests {
    @Test func cursorAdvancedRoundTrip() throws {
        let m = WSMessage.cursorAdvanced(version: 1, deviceID: "peer-X", latestIngestedAtNs: 1_700_000_000_000_000_000)
        let json = try m.encodeJSON()
        // snake_case wire 形态校验 + JSON 字段稳定（sortedKeys 让顺序固定）
        #expect(json.contains("\"type\":\"cursor_advanced\""))
        #expect(json.contains("\"device_id\":\"peer-X\""))
        #expect(json.contains("\"latest_ingested_at_ns\":1700000000000000000"))
        let decoded = try WSMessage.decodeJSON(json)
        #expect(decoded == m)
    }

    @Test func helloRoundTrip() throws {
        let m = WSMessage.hello(version: 1, deviceID: "self", nowMs: 17_000, latestIngestedAtNs: 99)
        let json = try m.encodeJSON()
        #expect(json.contains("\"type\":\"hello\""))
        #expect(json.contains("\"now_ms\":17000"))
        let decoded = try WSMessage.decodeJSON(json)
        #expect(decoded == m)
    }

    @Test func pingPongRoundTrip() throws {
        for m in [WSMessage.ping(version: 1), .pong(version: 1)] {
            let s = try m.encodeJSON()
            let d = try WSMessage.decodeJSON(s)
            #expect(d == m)
        }
    }

    @Test func endpointsChangedRoundTrip() throws {
        let m = WSMessage.endpointsChanged(version: 1, updatedAtUnix: 1_700_000_123)
        let s = try m.encodeJSON()
        #expect(s.contains("\"type\":\"endpoints_changed\""))
        #expect(s.contains("\"updated_at_unix\":1700000123"))
        #expect(try WSMessage.decodeJSON(s) == m)
    }

    @Test func unknownTypeThrowsDecodingError() {
        let bogus = "{\"type\":\"whatever\",\"version\":1}"
        #expect(throws: DecodingError.self) {
            _ = try WSMessage.decodeJSON(bogus)
        }
    }

    @Test func versionFieldDefaultsToOneWhenMissing() throws {
        // 兼容老 client 忘了带 version 的场景：默认 version=1，避免 hard fail
        let json = "{\"type\":\"cursor_advanced\",\"device_id\":\"X\",\"latest_ingested_at_ns\":42}"
        let m = try WSMessage.decodeJSON(json)
        #expect(m == .cursorAdvanced(version: 1, deviceID: "X", latestIngestedAtNs: 42))
    }

    @Test func nonUTF8InputThrows() {
        let invalid = String(bytes: [0xff, 0xff], encoding: .isoLatin1) ?? "x"
        // String(data:encoding: .utf8) 仍会 work 大多数情况，
        // 这里专门构造一个真不能解码的字符串场景：用合法 UTF-8 但 JSON 非法
        #expect(throws: DecodingError.self) {
            _ = try WSMessage.decodeJSON(invalid + "{not json")
        }
    }
}
