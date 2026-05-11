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

    /// Keychain 里 shared secret 的 account 名。HMAC 签名用。primary_url 为空时不需要。
    public var sharedSecretKeychainAccount: String?

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
        self.sharedSecretKeychainAccount = try c.decodeIfPresent(
            String.self, forKey: .sharedSecretKeychainAccount
        )
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
