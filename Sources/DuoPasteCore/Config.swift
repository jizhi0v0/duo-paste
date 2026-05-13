import Foundation

/// 进程启动时从 `~/Library/Application Support/duo-paste/config.json` 加载。
///
/// 缺文件 → 全默认值（standalone 模式，等价于 M1 行为）；
/// 文件存在但 JSON 解析失败 / 字段组合非法 → 启动 fast-fail，不静默吃掉错误。
public struct Config: Codable, Sendable, Equatable {
    /// 是否启动 Hummingbird server（暴露 /ingest /search /since /blob /health）。
    /// primary 角色为 true；standalone / 纯 client 为 false。
    public var serve: Bool

    /// server 监听 host。默认 127.0.0.1（仅本机）；上线时改 0.0.0.0 让 tailnet 可达。
    public var serveHost: String

    /// server 监听端口。
    public var servePort: Int

    /// true → server 起 HTTPS（用 tlsCertPath / tlsKeyPath 配的 PEM）；
    /// false → HTTP（依赖 Tailscale WG 加密）。
    public var serveTLS: Bool

    /// PEM 证书路径。`tailscale cert <hostname>` 输出的 `<hostname>.crt`。
    public var tlsCertPath: String?

    /// PEM 私钥路径。`tailscale cert <hostname>` 输出的 `<hostname>.key`。
    public var tlsKeyPath: String?

    /// 非空 → 启动 push worker，把本地 origin pending 推到这里。
    /// 为空 → 没有外部 primary，本机即权威源（standalone 或自己就是 primary）。
    public var primaryURL: URL?

    public var pull: PullConfig

    /// OCR 段：是否启用 + 语言 + blob 上限 + Vision 识别精度。详 plan vivid-scanning-vellum.md
    /// 第 3 刀。enabled=false → AppDelegate 不启 OCRWorker；CaptureService 仍标 pending
    /// （不动数据形态），用户翻回 true 后历史 pending 自然被处理
    public var ocr: OCRSettings

    /// 捕获守门：blob / text 字节上限。超过 → 跳过捕获（不写 DB 不写 blob），
    /// macOS pasteboard 自身仍可正常 Cmd+V 粘贴——只是不进 duo-paste 历史。
    /// 默认值见 CaptureLimits.default。
    public var capture: CaptureLimits

    /// 全局快捷键。默认 ⌥⌘V（跟硬编码历史值一致）。改了 config.json 后要重启 daemon
    public var hotkey: HotkeyConfig

    /// Keychain 里 shared secret 的 account 名。HMAC 签名用。primary_url 为空时不需要。
    public var sharedSecretKeychainAccount: String?

    /// 捕获字节守门。意外 Cmd+C 巨型对象（4K 长截图 / Cmd+A 大日志）→ 跳过入库，
    /// macOS 剪贴板自身正常工作（Cmd+V 立刻粘贴），只是不进 duo-paste 历史。
    ///
    /// 默认：blob 32MB / text 512KB。涵盖正常截图 + 留头部缓冲到 server cap
    /// (/blob=64MB, /ingest=1MB)。详见 CLAUDE.md "capture cap 默认值"。
    ///
    /// **作用域**：这是 *per-device capture policy*，不是 sync-wide invariant。Primary 的
    /// /ingest / /blob handler 不重新校验单字段大小——只校验 body 总上限
    /// (ingestBodyLimit=1MB / blobBodyLimit=64MB)。所以理论上 A 设备配 max_text_kb=900
    /// 推一条 900KB 文本，primary + 别的 client mirror 都接受。HMAC 签名 + 共享 secret
    /// 是已认证内部边界，threat model 允许 trust——server 总上限挡住极端 DoS 即可。
    public struct CaptureLimits: Codable, Sendable, Equatable {
        /// Blob (image / binary 等通过 pasteboard 拿到字节流的类型) 上限，字节。
        public var maxBlobBytes: Int
        /// Text (text/rtf/html/url) UTF-8 字节上限。
        /// 注意：跟 server `/ingest` body 1MB 上限留头部缓冲——
        /// JSON 编码 + 元数据（id / origin_device / source_app / preview...）
        /// 大约占 200B-1KB + escape 膨胀 ~1.3x，512KB 文本编码后 body 约 700KB。
        public var maxTextBytes: Int
        /// Blob (image / 同 sha 字节) 合并窗口（秒）。窗口内同 kind+blob_sha256 的重复粘贴
        /// 只刷 captured_at_ns，不插新行。默认 300（5 分钟）。
        /// 注意：**只**作用于 blob 路径（ingestBlob）；text 走 `textMergeWindowSec` 独立配置，
        /// 因为文本字节相等即同（不需要 sha 抽象），永久 dedup 比窗口语义更符合剪贴板心智。
        public var mergeWindowSec: Int
        /// Text (text/url/file 等文本路径) 合并窗口（秒）。
        /// `nil`（默认）→ 永久 dedup：任意时间内同 kind+text_full 的重复都合并 bump capturedAtNs。
        /// `0` → 完全禁用文本合并。`N>0` → N 秒内合并。
        public var textMergeWindowSec: Int?

        public static let `default` = CaptureLimits(
            maxBlobBytes: 32 * 1024 * 1024,
            maxTextBytes: 512 * 1024,
            mergeWindowSec: 300,
            textMergeWindowSec: nil
        )

        public init(
            maxBlobBytes: Int,
            maxTextBytes: Int,
            mergeWindowSec: Int = 300,
            textMergeWindowSec: Int? = nil
        ) {
            self.maxBlobBytes = maxBlobBytes
            self.maxTextBytes = maxTextBytes
            self.mergeWindowSec = mergeWindowSec
            self.textMergeWindowSec = textMergeWindowSec
        }

        enum CodingKeys: String, CodingKey {
            case maxBlobMB = "max_blob_mb"
            case maxTextKB = "max_text_kb"
            case mergeWindowSec = "merge_window_sec"
            case textMergeWindowSec = "text_merge_window_sec"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let blobMB = try c.decodeIfPresent(Int.self, forKey: .maxBlobMB) ?? 32
            let textKB = try c.decodeIfPresent(Int.self, forKey: .maxTextKB) ?? 512
            self.maxBlobBytes = blobMB * 1024 * 1024
            self.maxTextBytes = textKB * 1024
            self.mergeWindowSec = try c.decodeIfPresent(Int.self, forKey: .mergeWindowSec) ?? 300
            // 文本合并窗口缺省 nil = 永久。显式给 null / 不写 → nil。
            // contains() 判断让"key 存在但值为 null"也能映射到 nil（decodeIfPresent 会返回 nil）
            self.textMergeWindowSec = try c.decodeIfPresent(Int.self, forKey: .textMergeWindowSec)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(maxBlobBytes / (1024 * 1024), forKey: .maxBlobMB)
            try c.encode(maxTextBytes / 1024, forKey: .maxTextKB)
            try c.encode(mergeWindowSec, forKey: .mergeWindowSec)
            try c.encodeIfPresent(textMergeWindowSec, forKey: .textMergeWindowSec)
        }
    }

    public struct HotkeyConfig: Codable, Sendable, Equatable {
        /// 键位字符串：A-Z / 0-9 子集。大小写无关——内部按 uppercase 比对。
        /// 不支持 F1/Esc/Tab 这类特殊键——M4 简化版（剪贴板调出大多用字母组合，
        /// 用户拿 F-key 当主键的场景少；将来扩 keyToCode 表即可）
        public var key: String
        /// 修饰键子集，元素来自 {"cmd","option","control","shift"}。
        /// "command" / "alt" / "ctrl" 等别名在 carbon 转换层接受
        public var modifiers: [String]

        /// 默认 ⌥⌘V，跟历史硬编码一致——零回归
        public static let `default` = HotkeyConfig(key: "V", modifiers: ["cmd", "option"])

        public init(key: String, modifiers: [String]) {
            self.key = key
            self.modifiers = modifiers
        }

        enum CodingKeys: String, CodingKey {
            case key
            case modifiers
        }

        /// `key` 必须落在受支持字符集里。Carbon keyCode 转换不在这里——保持 Config
        /// 模块不依赖 Carbon。GlobalHotKey 调用方负责字符串 → keyCode 映射 + 报错
        public static let supportedKeys: Set<String> = {
            var set: Set<String> = []
            for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" { set.insert(String(c)) }
            for c in "0123456789" { set.insert(String(c)) }
            return set
        }()

        /// 修饰键别名归一化。失败抛 ConfigError（validate() 用）
        public static let supportedModifiers: Set<String> = [
            "cmd", "command",
            "option", "alt",
            "control", "ctrl",
            "shift",
        ]
    }

    /// OCR worker 配置段。AppDelegate 启动时把 `enabled=true` 翻译成 OCRWorker.Config
    /// 启 worker；`enabled=false` 不启。详 plan vivid-scanning-vellum.md 第 3 刀。
    public struct OCRSettings: Codable, Sendable, Equatable {
        /// false → 不启动 OCRWorker。CaptureService 仍写 ocr_state=pending；翻回 true
        /// 后这些历史会被处理（不在 capture 路径区分"开/关"避免增加状态空间）
        public var enabled: Bool
        /// Vision recognitionLanguages hint。按优先级排序；macOS 13+ 上
        /// automaticallyDetectsLanguage 还会自动猜，hint 仍作为模型偏好
        public var languages: [String]
        /// blob 字节超过此值 → 标 skipped 不喂 Vision。capture 端的 max_blob_mb 默认 32MB
        /// 是"防意外巨物入库"，本 cap 是"OCR 本身慢/内存峰值高"的另一类守门
        public var maxBlobMB: Int
        /// "accurate" / "fast"。默认 accurate——中文截图 fast 漏字明显
        public var recognitionLevel: String
        /// 同 batch 内每张 OCR 之间 sleep 毫秒。100ms 让前台 UI 不卡
        public var perItemPauseMs: Int

        public static let `default` = OCRSettings(
            enabled: true,
            languages: ["zh-Hans", "en-US"],
            maxBlobMB: 16,
            recognitionLevel: "accurate",
            perItemPauseMs: 100
        )

        public init(
            enabled: Bool,
            languages: [String],
            maxBlobMB: Int,
            recognitionLevel: String,
            perItemPauseMs: Int
        ) {
            self.enabled = enabled
            self.languages = languages
            self.maxBlobMB = maxBlobMB
            self.recognitionLevel = recognitionLevel
            self.perItemPauseMs = perItemPauseMs
        }

        enum CodingKeys: String, CodingKey {
            case enabled
            case languages
            case maxBlobMB = "max_blob_mb"
            case recognitionLevel = "recognition_level"
            case perItemPauseMs = "per_item_pause_ms"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = OCRSettings.default
            self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
            self.languages = try c.decodeIfPresent([String].self, forKey: .languages) ?? defaults.languages
            self.maxBlobMB = try c.decodeIfPresent(Int.self, forKey: .maxBlobMB) ?? defaults.maxBlobMB
            self.recognitionLevel = try c.decodeIfPresent(String.self, forKey: .recognitionLevel) ?? defaults.recognitionLevel
            self.perItemPauseMs = try c.decodeIfPresent(Int.self, forKey: .perItemPauseMs) ?? defaults.perItemPauseMs
        }
    }

    public struct PullConfig: Codable, Sendable, Equatable {
        /// true → 启动 pull worker，周期拉 primary 全量到 item_mirror。
        public var enabled: Bool
        public var intervalSec: Int
        /// true → blob 也预拉（默认懒拉：搜索结果点开时才拉）。
        public var eagerBlobs: Bool

        public static let `default` = PullConfig(enabled: false, intervalSec: 30, eagerBlobs: false)

        public init(enabled: Bool, intervalSec: Int, eagerBlobs: Bool) {
            self.enabled = enabled
            self.intervalSec = intervalSec
            self.eagerBlobs = eagerBlobs
        }

        enum CodingKeys: String, CodingKey {
            case enabled
            case intervalSec = "interval_sec"
            case eagerBlobs = "eager_blobs"
        }
    }

    public static let `default` = Config(
        serve: false,
        serveHost: "127.0.0.1",
        servePort: 8443,
        serveTLS: false,
        tlsCertPath: nil,
        tlsKeyPath: nil,
        primaryURL: nil,
        pull: .default,
        ocr: .default,
        capture: .default,
        hotkey: .default,
        sharedSecretKeychainAccount: nil
    )

    public init(
        serve: Bool,
        serveHost: String,
        servePort: Int,
        serveTLS: Bool,
        tlsCertPath: String?,
        tlsKeyPath: String?,
        primaryURL: URL?,
        pull: PullConfig,
        ocr: OCRSettings = .default,
        capture: CaptureLimits = .default,
        hotkey: HotkeyConfig = .default,
        sharedSecretKeychainAccount: String?
    ) {
        self.serve = serve
        self.serveHost = serveHost
        self.servePort = servePort
        self.serveTLS = serveTLS
        self.tlsCertPath = tlsCertPath
        self.tlsKeyPath = tlsKeyPath
        self.primaryURL = primaryURL
        self.pull = pull
        self.ocr = ocr
        self.capture = capture
        self.hotkey = hotkey
        self.sharedSecretKeychainAccount = sharedSecretKeychainAccount
    }

    enum CodingKeys: String, CodingKey {
        case serve
        case serveHost = "serve_host"
        case servePort = "serve_port"
        case serveTLS = "serve_tls"
        case tlsCertPath = "tls_cert_path"
        case tlsKeyPath = "tls_key_path"
        case primaryURL = "primary_url"
        case pull
        case ocr
        case capture
        case hotkey
        case sharedSecretKeychainAccount = "shared_secret_keychain_account"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.serve = try c.decodeIfPresent(Bool.self, forKey: .serve) ?? false
        self.serveHost = try c.decodeIfPresent(String.self, forKey: .serveHost) ?? "127.0.0.1"
        self.servePort = try c.decodeIfPresent(Int.self, forKey: .servePort) ?? 8443
        self.serveTLS = try c.decodeIfPresent(Bool.self, forKey: .serveTLS) ?? false
        self.tlsCertPath = try c.decodeIfPresent(String.self, forKey: .tlsCertPath)
        self.tlsKeyPath = try c.decodeIfPresent(String.self, forKey: .tlsKeyPath)
        if let s = try c.decodeIfPresent(String.self, forKey: .primaryURL), !s.isEmpty {
            // URL(string:) 出奇地宽松（接受 "not a url"），用 scheme 是否存在做硬约束。
            // 真实 primary_url 必然是 http/https。
            guard let url = URL(string: s),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  url.host != nil
            else {
                throw ConfigError.invalidPrimaryURL(s)
            }
            self.primaryURL = url
        } else {
            self.primaryURL = nil
        }
        self.pull = try c.decodeIfPresent(PullConfig.self, forKey: .pull) ?? .default
        self.ocr = try c.decodeIfPresent(OCRSettings.self, forKey: .ocr) ?? .default
        self.capture = try c.decodeIfPresent(CaptureLimits.self, forKey: .capture) ?? .default
        self.hotkey = try c.decodeIfPresent(HotkeyConfig.self, forKey: .hotkey) ?? .default
        self.sharedSecretKeychainAccount = try c.decodeIfPresent(
            String.self, forKey: .sharedSecretKeychainAccount
        )
    }

    /// 把 cfg 序列化写到 `path`（atomic + 0600 权限）。
    ///
    /// **保留未知字段**（含嵌套）：如果 path 已存在且能解析成 JSON dict，先用原 dict 做 base，
    /// 再用 cfg 的字段**逐 key 覆盖**——top-level 和 `pull` / `capture` 子 dict 都是 merge 而
    /// 非 replace。这样：
    /// - 用户/运维往 config.json 手动加的非 Config 字段不被吞掉（顶层注释 key、调试开关等）
    /// - `pull` / `capture` 子段内的未知键也不丢（未来新增字段、运维手动加的注解都安全）
    /// - 老版本 daemon 写回时不会误删新版本字段
    ///
    /// 写入前调 `validate()`，非法字段组合直接 throw，不写半成品文件。
    ///
    /// 唯一已知调用方：`Admin.promoteToPrimary`。普通启动路径只读不写。
    public static func write(_ cfg: Config, to path: URL) throws {
        try cfg.validate()

        var dict: [String: Any] = [:]
        let fm = FileManager.default
        if fm.fileExists(atPath: path.path),
           let data = try? Data(contentsOf: path),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            dict = parsed
        }

        dict[CodingKeys.serve.rawValue] = cfg.serve
        dict[CodingKeys.serveHost.rawValue] = cfg.serveHost
        dict[CodingKeys.servePort.rawValue] = cfg.servePort
        dict[CodingKeys.serveTLS.rawValue] = cfg.serveTLS
        Self.setOrRemove(&dict, CodingKeys.tlsCertPath.rawValue, cfg.tlsCertPath)
        Self.setOrRemove(&dict, CodingKeys.tlsKeyPath.rawValue, cfg.tlsKeyPath)
        Self.setOrRemove(&dict, CodingKeys.primaryURL.rawValue, cfg.primaryURL?.absoluteString)

        // P2 review fix: nested merge——读原 sub-dict 做 base 后只覆盖目标 key，保留任何
        // 未来字段或用户手动加的 sub-keys（之前是整段 replace，会丢嵌套未知字段）
        var pullDict = (dict[CodingKeys.pull.rawValue] as? [String: Any]) ?? [:]
        pullDict["enabled"] = cfg.pull.enabled
        pullDict["interval_sec"] = cfg.pull.intervalSec
        pullDict["eager_blobs"] = cfg.pull.eagerBlobs
        dict[CodingKeys.pull.rawValue] = pullDict

        var captureDict = (dict[CodingKeys.capture.rawValue] as? [String: Any]) ?? [:]
        captureDict["max_blob_mb"] = cfg.capture.maxBlobBytes / (1024 * 1024)
        captureDict["max_text_kb"] = cfg.capture.maxTextBytes / 1024
        captureDict["merge_window_sec"] = cfg.capture.mergeWindowSec
        // textMergeWindowSec nil → 移除 key（=永久 dedup 缺省语义）。非 nil → 写值。
        if let textWin = cfg.capture.textMergeWindowSec {
            captureDict["text_merge_window_sec"] = textWin
        } else {
            captureDict.removeValue(forKey: "text_merge_window_sec")
        }
        dict[CodingKeys.capture.rawValue] = captureDict

        // hotkey 同款 nested merge——用户/未来可能加 description / disabled 之类字段
        var hotkeyDict = (dict[CodingKeys.hotkey.rawValue] as? [String: Any]) ?? [:]
        hotkeyDict["key"] = cfg.hotkey.key
        hotkeyDict["modifiers"] = cfg.hotkey.modifiers
        dict[CodingKeys.hotkey.rawValue] = hotkeyDict

        // ocr 同款 nested merge——未来可能加 custom_words / debug_dump 等字段
        var ocrDict = (dict[CodingKeys.ocr.rawValue] as? [String: Any]) ?? [:]
        ocrDict["enabled"] = cfg.ocr.enabled
        ocrDict["languages"] = cfg.ocr.languages
        ocrDict["max_blob_mb"] = cfg.ocr.maxBlobMB
        ocrDict["recognition_level"] = cfg.ocr.recognitionLevel
        ocrDict["per_item_pause_ms"] = cfg.ocr.perItemPauseMs
        dict[CodingKeys.ocr.rawValue] = ocrDict

        Self.setOrRemove(&dict, CodingKeys.sharedSecretKeychainAccount.rawValue,
                         cfg.sharedSecretKeychainAccount)

        let out = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        )
        try fm.createDirectory(at: path.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try out.write(to: path, options: [.atomic])
        // 跟 shared-secret 一致：config 里有 keychain_account / tls 路径等敏感字段，
        // 默认 0600 防止他用户读
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    private static func setOrRemove<T>(_ dict: inout [String: Any], _ key: String, _ value: T?) {
        if let v = value { dict[key] = v } else { dict.removeValue(forKey: key) }
    }

    /// 从 `path` 加载。文件不存在 → 返回 `.default`。其他错误（JSON 损坏、字段非法）→ throw。
    public static func load(from path: URL) throws -> Config {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else {
            return .default
        }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw ConfigError.readFailed(path: path, underlying: error)
        }
        let cfg: Config
        do {
            cfg = try JSONDecoder().decode(Config.self, from: data)
        } catch let e as ConfigError {
            throw e
        } catch {
            throw ConfigError.decodeFailed(path: path, underlying: error)
        }
        try cfg.validate()
        return cfg
    }

    /// 字段组合校验。语义上无意义的组合在启动时就报错，比留到运行时悄悄失败好。
    public func validate() throws {
        if pull.enabled && primaryURL == nil {
            throw ConfigError.invalidCombination(
                "pull.enabled=true 但 primary_url 为空——没有可拉取的源"
            )
        }
        if serve && primaryURL != nil {
            throw ConfigError.invalidCombination(
                "serve=true 且 primary_url 非空——primary 不应同时作为别人的 client"
            )
        }
        if pull.intervalSec < 1 {
            throw ConfigError.invalidCombination("pull.interval_sec 必须 >= 1")
        }
        if capture.maxBlobBytes < 1 {
            throw ConfigError.invalidCombination("capture.max_blob_mb 必须 >= 1")
        }
        if capture.maxTextBytes < 1 {
            throw ConfigError.invalidCombination("capture.max_text_kb 必须 >= 1")
        }
        if capture.mergeWindowSec < 0 {
            throw ConfigError.invalidCombination("capture.merge_window_sec 必须 >= 0")
        }
        if let textWin = capture.textMergeWindowSec, textWin < 0 {
            throw ConfigError.invalidCombination(
                "capture.text_merge_window_sec 必须 >= 0 或省略（省略=永久 dedup）"
            )
        }
        if serve && !(1...65535).contains(servePort) {
            throw ConfigError.invalidCombination("serve_port 超界 (1-65535)：\(servePort)")
        }
        if serveTLS {
            if !serve {
                throw ConfigError.invalidCombination("serve_tls=true 但 serve=false")
            }
            guard let cert = tlsCertPath, !cert.isEmpty,
                  let key = tlsKeyPath, !key.isEmpty else {
                throw ConfigError.invalidCombination("serve_tls=true 时 tls_cert_path 和 tls_key_path 必填")
            }
            // 路径存在性检查放到 server 启动时——避免单元测试要求文件存在
            _ = cert; _ = key
        }
        // hotkey 字段校验——拼写错的 modifier / 不支持的 key 在启动时就 throw，
        // 不会让 daemon 起来后 GlobalHotKey.register 报神秘 Carbon 错误码
        let keyNorm = hotkey.key.uppercased()
        if !HotkeyConfig.supportedKeys.contains(keyNorm) {
            throw ConfigError.invalidCombination(
                "hotkey.key 不支持：\(hotkey.key)。当前只支持 A-Z 和 0-9"
            )
        }
        if hotkey.modifiers.isEmpty {
            throw ConfigError.invalidCombination(
                "hotkey.modifiers 不能为空——纯字母键会跟普通输入冲突"
            )
        }
        for m in hotkey.modifiers {
            if !HotkeyConfig.supportedModifiers.contains(m.lowercased()) {
                throw ConfigError.invalidCombination(
                    "hotkey.modifiers 不支持：\(m)。可选：cmd / option / control / shift"
                )
            }
        }
        // shift-only 等于全局拦截大写字母（Shift+V = V），让用户没法在任何 app 输入大写。
        // 必须至少有一个 cmd/option/control 把组合从"普通输入"里拉出来
        let nonShift = hotkey.modifiers.contains { m in
            let lower = m.lowercased()
            return lower == "cmd" || lower == "command"
                || lower == "option" || lower == "alt"
                || lower == "control" || lower == "ctrl"
        }
        if !nonShift {
            throw ConfigError.invalidCombination(
                "hotkey.modifiers 不能只有 shift——会拦截所有大写字母输入。请加 cmd / option / control"
            )
        }
        // ocr 字段校验
        if !["accurate", "fast"].contains(ocr.recognitionLevel.lowercased()) {
            throw ConfigError.invalidCombination(
                "ocr.recognition_level 必须是 'accurate' 或 'fast'：\(ocr.recognitionLevel)"
            )
        }
        if ocr.languages.isEmpty {
            throw ConfigError.invalidCombination("ocr.languages 不能为空")
        }
        if ocr.maxBlobMB < 1 {
            throw ConfigError.invalidCombination("ocr.max_blob_mb 必须 >= 1")
        }
        if ocr.perItemPauseMs < 0 {
            throw ConfigError.invalidCombination("ocr.per_item_pause_ms 必须 >= 0")
        }
    }

    /// 是否要给本机捕获标 pending（= 有 primary 要推）。
    /// CaptureService 当前用 DatabaseRole 表达同一件事；这里给一个语义清晰的别名。
    public var capturesNeedPush: Bool { primaryURL != nil }

    public var derivedDatabaseRole: DatabaseRole {
        capturesNeedPush ? .client : .primary
    }

    /// 用户可读的单行摘要，启动日志用。
    public var summary: String {
        let scheme = serveTLS ? "https" : "http"
        switch (serve, primaryURL) {
        case (false, nil): return "standalone"
        case (true, nil):  return "primary @ \(scheme)://\(serveHost):\(servePort)"
        case (false, let url?): return pull.enabled ? "client+mirror→\(url.absoluteString)" : "client→\(url.absoluteString)"
        case (true, _?): return "INVALID"  // validate() 应已拦截
        }
    }
}

public enum ConfigError: Error, CustomStringConvertible, Sendable {
    case readFailed(path: URL, underlying: Error)
    case decodeFailed(path: URL, underlying: Error)
    case invalidPrimaryURL(String)
    case invalidCombination(String)

    public var description: String {
        switch self {
        case .readFailed(let p, let e):
            return "读取 config 失败 (\(p.path)): \(e)"
        case .decodeFailed(let p, let e):
            return "解析 config JSON 失败 (\(p.path)): \(e)"
        case .invalidPrimaryURL(let s):
            return "primary_url 不是合法 URL: \(s)"
        case .invalidCombination(let msg):
            return "config 字段组合非法: \(msg)"
        }
    }
}
