import Foundation

/// 进程启动时从 `~/Library/Application Support/duo-paste/config.json` 加载。
///
/// 缺文件 → 全默认值（standalone 模式，等价于 M1 行为）；
/// 文件存在但 JSON 解析失败 / 字段组合非法 → 启动 fast-fail，不静默吃掉错误。
public struct Config: Codable, Sendable, Equatable {
    /// 是否启动 Hummingbird mesh server（暴露 health / sync / mutation 等路由）。
    /// mesh 中每台 Mac 都为 true；standalone 默认为 false。
    public var serve: Bool

    /// server 监听 host。默认 127.0.0.1（仅本机）；上线时改 0.0.0.0 让 tailnet 可达。
    public var serveHost: String

    /// server 监听端口。
    public var servePort: Int

    /// true → server 起 HTTPS（用 tlsCertPath / tlsKeyPath 配的 PEM）；
    /// false → HTTP（依赖 Tailscale WG 加密）。
    public var serveTLS: Bool

    /// PEM 证书路径。Ponte 双路由场景必须包含 tailnet + Ponte host 两个 SAN。
    public var tlsCertPath: String?

    /// PEM 私钥路径，与 `tlsCertPath` 的叶子证书匹配。
    public var tlsKeyPath: String?

    /// Mesh 拓扑下的对端 peer 列表。每台机器把别的所有 mac 写到这里——本机会为
    /// 每个 peer 起 PullWorker（拉对端 /since）+ WSNotificationClient（订阅对端
    /// /sync/ws cursor_advanced 通知）。空数组 = standalone（不主动连任何对端）。
    public var peers: [PeerConfig]

    /// Mesh 全局参数：pull 周期 / WS 心跳 / dedup 窗 / 时钟偏移阈值 等。
    /// 各 peer 共享同一份配置——不需要 per-peer 调参（plan §"Config schema"）。
    public var mesh: MeshConfig

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

    /// 捕获字节守门。意外 Cmd+C 巨型对象（4K 长截图 / Cmd+A 大日志）→ 跳过入库，
    /// macOS 剪贴板自身正常工作（Cmd+V 立刻粘贴），只是不进 duo-paste 历史。
    ///
    /// 默认：blob 32MB / text 512KB。涵盖正常截图并避免意外巨物进入历史。
    ///
    /// **作用域**：这是 per-device capture policy，不是 sync-wide invariant。各 owner
    /// 可按设备调整；peer 通过 `/since` 接收已认证的历史元数据，blob 再按需懒拉。
    public struct CaptureLimits: Codable, Sendable, Equatable {
        /// Blob (image / binary 等通过 pasteboard 拿到字节流的类型) 上限，字节。
        public var maxBlobBytes: Int
        /// Text (text/rtf/html/url) UTF-8 字节上限。
        /// 上限按 UTF-8 原始内容计算；默认 512KB，给 item 元数据和编码开销留余量。
        public var maxTextBytes: Int
        /// 永不进入 duo-paste 历史的 source app bundle IDs。per-device 配置；匹配忽略
        /// 大小写与首尾空白。跳过不影响系统 pasteboard / Cmd+V。
        public var excludedBundleIDs: [String]
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
            textMergeWindowSec: nil,
            excludedBundleIDs: []
        )

        public init(
            maxBlobBytes: Int,
            maxTextBytes: Int,
            mergeWindowSec: Int = 300,
            textMergeWindowSec: Int? = nil,
            excludedBundleIDs: [String] = []
        ) {
            self.maxBlobBytes = maxBlobBytes
            self.maxTextBytes = maxTextBytes
            self.mergeWindowSec = mergeWindowSec
            self.textMergeWindowSec = textMergeWindowSec
            self.excludedBundleIDs = excludedBundleIDs
        }

        enum CodingKeys: String, CodingKey {
            case maxBlobMB = "max_blob_mb"
            case maxTextKB = "max_text_kb"
            case mergeWindowSec = "merge_window_sec"
            case textMergeWindowSec = "text_merge_window_sec"
            case excludedBundleIDs = "excluded_bundle_ids"
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
            self.excludedBundleIDs = try c.decodeIfPresent(
                [String].self,
                forKey: .excludedBundleIDs
            ) ?? []
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(maxBlobBytes / (1024 * 1024), forKey: .maxBlobMB)
            try c.encode(maxTextBytes / 1024, forKey: .maxTextKB)
            try c.encode(mergeWindowSec, forKey: .mergeWindowSec)
            try c.encodeIfPresent(textMergeWindowSec, forKey: .textMergeWindowSec)
            try c.encode(excludedBundleIDs, forKey: .excludedBundleIDs)
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
        /// 模块不依赖 Carbon。GlobalHotKey 调用方负责字符串 → keyCode 映射 + 报错。
        ///
        /// 覆盖范围：A-Z + 0-9 + 常用 ANSI 标点符号（Paste.app 风格的 `⌘\` / `⌘;`
        /// 这类组合）。**必须**跟 GlobalHotKey.HotkeyTranslation.keyToCode 表保持同步——
        /// Config.validate 通过但 translate 失败 = 程序员错误
        public static let supportedKeys: Set<String> = {
            var set: Set<String> = []
            for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" { set.insert(String(c)) }
            for c in "0123456789" { set.insert(String(c)) }
            // ANSI 标点（按 Carbon kVK_ANSI_* 常量覆盖范围）
            for s in ["\\", "/", ";", "'", ",", ".", "[", "]", "=", "-", "`"] {
                set.insert(s)
            }
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

    /// Mesh 对端 peer。`url` 必填指向对端 server（http/https，scheme 决定 WS 走 ws/wss）。
    /// `deviceID` 可选——`mesh-init` 写新 config 时一般不知道（要等首次 /health 探测才能学到），
    /// 留 nil 让 PullWorker 跑学习模式（首次 tick 时把对端 device_id stamp 进 pull_cursor）。
    /// 显式给 deviceID 走严格模式：peer URL 指错机器时 PullWorker 立刻 transient skip 不污染 DB。
    ///
    /// **可选 `pullURL`**：fetch-missing / PullWorker / paste-fetcher 走的"快路径"URL，
    /// 一般是 `*.sgponte`（Surge Ponte 域名，走 Surge HTTP proxy → ponte 隧道）。配了 →
    /// 这些拉取路径用 pullURL；没配 → fallback 回 url。
    /// **WSNotificationClient 永远用 url**（NIO WS client 不读系统 proxy，跑不了 ponte，
    /// tailscale magic DNS 才解析得到）。
    public struct PeerConfig: Codable, Sendable, Equatable {
        public var url: URL
        public var deviceID: String?
        public var pullURL: URL?

        public init(url: URL, deviceID: String? = nil, pullURL: URL? = nil) {
            self.url = url
            self.deviceID = deviceID
            self.pullURL = pullURL
        }

        /// PullWorker / fetch-missing / paste-fetcher 走的拉取 URL：优先 pullURL，
        /// 没配 fallback 到 url。WS 通知层不应该用这个 helper（永远用 .url）。
        public var effectivePullURL: URL { pullURL ?? url }

        enum CodingKeys: String, CodingKey {
            case url
            case deviceID = "device_id"
            case pullURL = "pull_url"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let s = try c.decode(String.self, forKey: .url)
            // URL(string:) 接受很多畸形串；scheme + host guard 防"not a url"误读
            guard let u = URL(string: s),
                  let scheme = u.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  u.host != nil
            else {
                throw ConfigError.invalidPeerURL(s)
            }
            self.url = u
            self.deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID)
            if let pullStr = try c.decodeIfPresent(String.self, forKey: .pullURL) {
                guard let pu = URL(string: pullStr),
                      let pscheme = pu.scheme?.lowercased(),
                      ["http", "https"].contains(pscheme),
                      pu.host != nil
                else {
                    throw ConfigError.invalidPeerURL("pull_url: \(pullStr)")
                }
                self.pullURL = pu
            } else {
                self.pullURL = nil
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(url.absoluteString, forKey: .url)
            try c.encodeIfPresent(deviceID, forKey: .deviceID)
            try c.encodeIfPresent(pullURL?.absoluteString, forKey: .pullURL)
        }
    }

    /// Mesh 全局参数。各 peer 共享，不分 per-peer 配置。
    ///
    /// **用户可见字段**（settings window / config.json 都暴露）：
    /// - `enabled` / `pullIntervalSec` / `wsEnabled` / `storageMode`
    /// - `crossDeviceDedupWindowNs` / `deleteCascadeEnabled`（plan hashed-allen §D §C 回滚口）
    ///
    /// **历史 tuning 字段已撤掉**（plan §settings-cleanup）：内部 backoff /
    /// WS timing / clock skew threshold 都不再从 config 读，统一走 worker / broadcaster
    /// 的硬编码 default。老 config.json 里残留 `pull_batch_limit / pull_initial_backoff_sec /
    /// pull_max_backoff_sec / clock_skew_warn_ms /
    /// ws_reconnect_initial_sec / ws_reconnect_max_sec / ws_heartbeat_sec / ws_rotation_sec`
    /// 键会被 decoder 忽略不报错；Config.write 不再序列化这些键，保留升级用户的 config
    /// 干净（nested merge 会保留任何未知键，但因为这些键不在 write 列表里，下次写回会被
    /// 自动洗掉）
    public struct MeshConfig: Codable, Sendable, Equatable {
        /// false → 退化为 standalone（peers 字段也应为空；validate 强制）。
        public var enabled: Bool
        /// PullWorker 周期 floor。WS cursor_advanced 通了仍每 N 秒拉一次兜底（防 WS 漏推）。
        public var pullIntervalSec: Int
        /// blob 存储模式。`.full`（默认）= PullWorker 每 tick 顺路拉新行的 blob 字节做完整
        /// mirror；`.optimized` = 不拉字节，UI 需要看到时按需走 lazy GET /blob/<sha>。
        /// 老 `eager_blobs` 键的兼容：见 MeshConfig.init(from:) decode 路径。
        public var storageMode: StorageMode
        /// false → 关 WS 通知层退化为周期 pull（按 pullIntervalSec）。
        public var wsEnabled: Bool
        /// 跨设备 Continuity dedup 时间窗（纳秒）。默 0 = 关 dedup，让 cross-device 副本
        /// 老实进 mirror，靠 UI fold（文本永久 + 近时间跨-origin 同 sha blob）兜底——保证两台 Mac 行集合
        /// 对称（cascade 删除依赖这个对称性）。5_000_000_000 = 历史行为，单台机器临时
        /// 回滚用。plan hashed-allen §D
        public var crossDeviceDedupWindowNs: Int64
        /// true（默）= `Database.softDelete` 删一条时 cascade 同 text_full 所有 active
        /// sibling。false = 紧急回退，退化为只删单 id（plan hashed-allen §C 回滚口）。
        /// 控制粒度在 daemon 级，重启 daemon 生效（kickstart -k）。
        public var deleteCascadeEnabled: Bool

        public static let `default` = MeshConfig(
            enabled: true,
            pullIntervalSec: 30,
            storageMode: .default,
            wsEnabled: true,
            crossDeviceDedupWindowNs: 0,
            deleteCascadeEnabled: true
        )

        public init(
            enabled: Bool,
            pullIntervalSec: Int,
            storageMode: StorageMode,
            wsEnabled: Bool,
            crossDeviceDedupWindowNs: Int64 = 0,
            deleteCascadeEnabled: Bool = true
        ) {
            self.enabled = enabled
            self.pullIntervalSec = pullIntervalSec
            self.storageMode = storageMode
            self.wsEnabled = wsEnabled
            self.crossDeviceDedupWindowNs = crossDeviceDedupWindowNs
            self.deleteCascadeEnabled = deleteCascadeEnabled
        }

        enum CodingKeys: String, CodingKey {
            case enabled
            case pullIntervalSec = "pull_interval_sec"
            case storageMode = "storage_mode"
            case eagerBlobs = "eager_blobs"   // 老键，decode-only 兼容；encode 走 storageMode
            case wsEnabled = "ws_enabled"
            case crossDeviceDedupWindowNs = "cross_device_dedup_window_ns"
            case deleteCascadeEnabled = "delete_cascade_enabled"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = MeshConfig.default
            self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
            self.pullIntervalSec = try c.decodeIfPresent(Int.self, forKey: .pullIntervalSec) ?? d.pullIntervalSec
            // storage_mode 解码顺序（plan cloudy-mirroring-walnut 老 config 兼容）：
            //   1. 新键 storage_mode 显式给 → 用它
            //   2. 否则尝老键 eager_blobs：true/false 都映射 .full
            //   3. 都缺则用 default (.full)
            if let mode = try c.decodeIfPresent(StorageMode.self, forKey: .storageMode) {
                self.storageMode = mode
            } else if (try c.decodeIfPresent(Bool.self, forKey: .eagerBlobs)) != nil {
                self.storageMode = .full
            } else {
                self.storageMode = d.storageMode
            }
            self.wsEnabled = try c.decodeIfPresent(Bool.self, forKey: .wsEnabled) ?? d.wsEnabled
            self.crossDeviceDedupWindowNs = try c.decodeIfPresent(Int64.self, forKey: .crossDeviceDedupWindowNs) ?? d.crossDeviceDedupWindowNs
            self.deleteCascadeEnabled = try c.decodeIfPresent(Bool.self, forKey: .deleteCascadeEnabled) ?? d.deleteCascadeEnabled
        }

        // 显式 encode：`eagerBlobs` CodingKey 是 decode-only 兼容键，没有匹配 property，
        // Swift 不能自动 synthesize Encodable。Config.write 走 JSON dict 路径不依赖这个
        // encode，但 Codable 协议契约要求覆盖
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(enabled, forKey: .enabled)
            try c.encode(pullIntervalSec, forKey: .pullIntervalSec)
            try c.encode(storageMode, forKey: .storageMode)
            try c.encode(wsEnabled, forKey: .wsEnabled)
            try c.encode(crossDeviceDedupWindowNs, forKey: .crossDeviceDedupWindowNs)
            try c.encode(deleteCascadeEnabled, forKey: .deleteCascadeEnabled)
        }
    }

    public static let `default` = Config(
        serve: false,
        serveHost: "127.0.0.1",
        servePort: 8443,
        serveTLS: false,
        tlsCertPath: nil,
        tlsKeyPath: nil,
        peers: [],
        mesh: .default,
        ocr: .default,
        capture: .default,
        hotkey: .default
    )

    public init(
        serve: Bool,
        serveHost: String,
        servePort: Int,
        serveTLS: Bool,
        tlsCertPath: String?,
        tlsKeyPath: String?,
        peers: [PeerConfig],
        mesh: MeshConfig = .default,
        ocr: OCRSettings = .default,
        capture: CaptureLimits = .default,
        hotkey: HotkeyConfig = .default
    ) {
        self.serve = serve
        self.serveHost = serveHost
        self.servePort = servePort
        self.serveTLS = serveTLS
        self.tlsCertPath = tlsCertPath
        self.tlsKeyPath = tlsKeyPath
        self.peers = peers
        self.mesh = mesh
        self.ocr = ocr
        self.capture = capture
        self.hotkey = hotkey
    }

    enum CodingKeys: String, CodingKey {
        case serve
        case serveHost = "serve_host"
        case servePort = "serve_port"
        case serveTLS = "serve_tls"
        case tlsCertPath = "tls_cert_path"
        case tlsKeyPath = "tls_key_path"
        case peers
        case mesh
        case ocr
        case capture
        case hotkey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.serve = try c.decodeIfPresent(Bool.self, forKey: .serve) ?? false
        self.serveHost = try c.decodeIfPresent(String.self, forKey: .serveHost) ?? "127.0.0.1"
        self.servePort = try c.decodeIfPresent(Int.self, forKey: .servePort) ?? 8443
        self.serveTLS = try c.decodeIfPresent(Bool.self, forKey: .serveTLS) ?? false
        self.tlsCertPath = try c.decodeIfPresent(String.self, forKey: .tlsCertPath)
        self.tlsKeyPath = try c.decodeIfPresent(String.self, forKey: .tlsKeyPath)
        self.peers = try c.decodeIfPresent([PeerConfig].self, forKey: .peers) ?? []
        self.mesh = try c.decodeIfPresent(MeshConfig.self, forKey: .mesh) ?? .default
        self.ocr = try c.decodeIfPresent(OCRSettings.self, forKey: .ocr) ?? .default
        self.capture = try c.decodeIfPresent(CaptureLimits.self, forKey: .capture) ?? .default
        self.hotkey = try c.decodeIfPresent(HotkeyConfig.self, forKey: .hotkey) ?? .default
    }

    /// 把 cfg 序列化写到 `path`（atomic + 0600 权限）。
    ///
    /// **保留未知字段**（含嵌套）：如果 path 已存在且能解析成 JSON dict，先用原 dict 做 base，
    /// 再用 cfg 的字段**逐 key 覆盖**——top-level 和子 dict 都是 merge 而非 replace。
    /// **数组例外**：`peers` 数组没法 merge（每条目顺序 + 字段语义跟"未知字段"无关），
    /// 直接 replace。
    ///
    /// PR 5 mesh-init 写新格式 config 时**显式 removeValue 老字段** `primary_url` / `pull`，
    /// 避免老 daemon 留下来的字段跟新字段冲突。
    ///
    /// 写入前调 `validate()`，非法字段组合直接 throw，不写半成品文件。
    public static func write(_ cfg: Config, to path: URL) throws {
        try cfg.validate()

        var dict: [String: Any] = [:]
        let fm = FileManager.default
        if fm.fileExists(atPath: path.path),
           let data = try? Data(contentsOf: path),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            dict = parsed
        }

        // PR 5：清掉老 schema 的 primary_url / pull——升级路径上 mesh-init 写新 config
        // 时这两 key 一定要消失，否则启动时 Decodable 不会因为有未知字段报错（已经
        // decodeIfPresent + 缺省值），但用户读 config.json 会看到语义冲突的两套字段
        dict.removeValue(forKey: "primary_url")
        dict.removeValue(forKey: "pull")

        dict[CodingKeys.serve.rawValue] = cfg.serve
        dict[CodingKeys.serveHost.rawValue] = cfg.serveHost
        dict[CodingKeys.servePort.rawValue] = cfg.servePort
        dict[CodingKeys.serveTLS.rawValue] = cfg.serveTLS
        Self.setOrRemove(&dict, CodingKeys.tlsCertPath.rawValue, cfg.tlsCertPath)
        Self.setOrRemove(&dict, CodingKeys.tlsKeyPath.rawValue, cfg.tlsKeyPath)

        // peers 数组 replace（数组无嵌套 merge 语义；每条 PeerConfig 是值类型，整体覆盖）。
        // 序列化用 JSONEncoder 统一 snake_case：encode → decode 回 [[String: Any]] 嵌进 dict
        let peersJSON = try JSONEncoder().encode(cfg.peers)
        dict[CodingKeys.peers.rawValue] = (try? JSONSerialization.jsonObject(with: peersJSON)) ?? []

        // mesh 段 nested merge——读原 sub-dict 做 base，只覆盖 cfg 内字段，保留未来字段。
        // **plan settings-cleanup**：老 tuning 键（pull_batch_limit / pull_initial_backoff_sec /
        // pull_max_backoff_sec / clock_skew_warn_ms /
        // ws_reconnect_initial_sec / ws_reconnect_max_sec / ws_heartbeat_sec / ws_rotation_sec）
        // 显式 removeValue 洗掉——之前 config.json 可能写过这些；升级路径上 Config.write
        // 一次后老字段从磁盘消失
        var meshDict = (dict[CodingKeys.mesh.rawValue] as? [String: Any]) ?? [:]
        meshDict["enabled"] = cfg.mesh.enabled
        meshDict["pull_interval_sec"] = cfg.mesh.pullIntervalSec
        meshDict["storage_mode"] = cfg.mesh.storageMode.rawValue
        meshDict["ws_enabled"] = cfg.mesh.wsEnabled
        // plan hashed-allen §D §C：重新引入 cross_device_dedup_window_ns（default 0）
        // 和 delete_cascade_enabled（default true）作为 mesh first-class 字段
        meshDict["cross_device_dedup_window_ns"] = cfg.mesh.crossDeviceDedupWindowNs
        meshDict["delete_cascade_enabled"] = cfg.mesh.deleteCascadeEnabled
        // 老 eager_blobs 键洗掉——升级后 config.json 不再含 PR cloudy-mirroring-walnut
        // 之前的 schema 字段，避免用户读 config 时看到两套语义冲突的字段
        meshDict.removeValue(forKey: "eager_blobs")
        // 老内部 tuning 字段——下沉到 worker / broadcaster default 后从 config 移除
        for legacy in [
            "pull_batch_limit", "pull_initial_backoff_sec", "pull_max_backoff_sec",
            "clock_skew_warn_ms",
            "ws_reconnect_initial_sec", "ws_reconnect_max_sec",
            "ws_heartbeat_sec", "ws_rotation_sec",
        ] {
            meshDict.removeValue(forKey: legacy)
        }
        dict[CodingKeys.mesh.rawValue] = meshDict

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
        captureDict["excluded_bundle_ids"] = cfg.capture.excludedBundleIDs
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

        // plan settings-cleanup：撤掉 shared_secret_keychain_account（从未在启动路径上读，
        // shared-secret 始终走文件路径）。老 config 里残留的键 → 这里显式洗掉
        dict.removeValue(forKey: "shared_secret_keychain_account")

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
        if mesh.enabled && peers.isEmpty && !serve {
            // mesh 开启但既无对端可拉、本机也不 serve 让别人来连——配置无意义
            // standalone 部署应当 mesh.enabled=false 或显式留 peers 空 + serve=false（合法的独立模式）
            // 这里只当用户标明 mesh.enabled=true 还啥都没配时才报，让 standalone 隐式 mesh.enabled=true
            // + peers 空通过（因为 default 就是这样）
        }
        if mesh.pullIntervalSec < 1 {
            throw ConfigError.invalidCombination("mesh.pull_interval_sec 必须 >= 1")
        }
        // peers 内 url 重复 / device_id 重复检查——启动时撞了立刻报，免得运行时
        // 两个 PullWorker 抢同一行 cursor / 同一份 mirror
        var seenURLs = Set<String>()
        var seenDeviceIDs = Set<String>()
        for p in peers {
            let key = p.url.absoluteString
            if !seenURLs.insert(key).inserted {
                throw ConfigError.invalidCombination("peers 列表里 url 重复：\(key)")
            }
            if let did = p.deviceID, !did.isEmpty {
                if !seenDeviceIDs.insert(did).inserted {
                    throw ConfigError.invalidCombination("peers 列表里 device_id 重复：\(did)")
                }
            }
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
        var seenExcludedBundleIDs = Set<String>()
        for raw in capture.excludedBundleIDs {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
                throw ConfigError.invalidCombination(
                    "capture.excluded_bundle_ids 必须是非空且不含空白的 bundle ID：\(raw)"
                )
            }
            if !seenExcludedBundleIDs.insert(trimmed.lowercased()).inserted {
                throw ConfigError.invalidCombination(
                    "capture.excluded_bundle_ids 重复：\(trimmed)"
                )
            }
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
                "hotkey.key 不支持：\(hotkey.key)。当前支持 A-Z / 0-9 / 标点 \\/;',.[]=-`"
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

    /// 用户可读的单行摘要，启动日志用。
    /// Mesh 拓扑下不再有 primary/client 角色，只描述 serve 状态 + peer 数。
    public var summary: String {
        let scheme = serveTLS ? "https" : "http"
        let serveDesc = serve ? "serve@\(scheme)://\(serveHost):\(servePort)" : "no-serve"
        if peers.isEmpty {
            return serve ? "standalone · \(serveDesc)" : "standalone"
        }
        let peerCount = peers.count
        let wsState = mesh.wsEnabled ? "ws=on" : "ws=off"
        return "mesh · \(peerCount) peer\(peerCount == 1 ? "" : "s") · \(serveDesc) · \(wsState)"
    }
}

public enum ConfigError: Error, CustomStringConvertible, Sendable {
    case readFailed(path: URL, underlying: Error)
    case decodeFailed(path: URL, underlying: Error)
    case invalidPeerURL(String)
    case invalidCombination(String)

    public var description: String {
        switch self {
        case .readFailed(let p, let e):
            return "读取 config 失败 (\(p.path)): \(e)"
        case .decodeFailed(let p, let e):
            return "解析 config JSON 失败 (\(p.path)): \(e)"
        case .invalidPeerURL(let s):
            return "peer url 不是合法 http(s) URL: \(s)"
        case .invalidCombination(let msg):
            return "config 字段组合非法: \(msg)"
        }
    }
}
