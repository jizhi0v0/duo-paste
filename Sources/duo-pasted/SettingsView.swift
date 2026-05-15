import SwiftUI
import AppKit
import DuoPasteCore
import DuoPasteSync

/// macOS Settings 窗口入口。三个 tab：常规 / OCR / 关于。
///
/// 设计：
/// - 读写 `~/Library/Application Support/duo-paste/config.json`。所有改动**需要重启 daemon
///   才能生效**——SwiftUI 端只写盘 + 弹「需要 launchctl kickstart」提示，daemon 启动时
///   读 config 时机依赖 launchd 拉起新进程
/// - 通过 `AppDelegate.shared` 取活的 AppState（device-id / mode summary / mesh status）
/// - 「关于」tab 的「补齐缺失 blob」按钮直接调 `Admin.fetchMissingBlobs`（跟 CLI
///   `mesh-fetch-missing` 同款实现），跑完弹结果
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("常规", systemImage: "gearshape") }
            OCRSettingsTab()
                .tabItem { Label("OCR", systemImage: "text.viewfinder") }
            AboutSettingsTab()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 520)
    }
}

// MARK: - 配置读写共用

/// 读 config + 处理 form 状态 + 写回。所有 tab 共用一份 working copy，
/// 「应用」按钮按 tab 分散触发 Config.write。
@MainActor
@Observable
final class SettingsModel {
    /// 当前磁盘上的 config 路径
    let configPath: URL
    /// 读盘后的 working copy；UI 直接 bind 编辑
    var config: Config
    /// 启动时读到的 baseline，对比看哪些字段 dirty
    private(set) var initial: Config
    /// 最近一次写盘的状态文案（绿色「已应用」/ 红色「写盘失败：…」）
    var statusMessage: String?
    var statusIsError: Bool = false

    init() {
        let paths = Paths.makeDefault()
        self.configPath = paths.configFile
        let cfg = (try? Config.load(from: paths.configFile)) ?? .default
        self.config = cfg
        self.initial = cfg
    }

    var isDirty: Bool { config != initial }

    /// dirty 字段是否仅限「能热重载」的范围。hotkey 改动可以热重载（GlobalHotKey.register
    /// 幂等）；其他字段（storage_mode / capture / mesh / ocr）要重 spawn 对应 worker，
    /// 当前架构没暴露 hot reload API，所以提示重启 daemon。
    /// 用 keypath 比较避免漏字段——任何 != initial 的非 hotkey 改动都标 needsRestart
    var needsRestart: Bool {
        guard isDirty else { return false }
        // 把 hotkey 拿掉对比剩余字段
        var a = config
        let b = initial
        a.hotkey = b.hotkey
        return a != b
    }

    /// 写回磁盘；成功后把 initial 同步为 config（之后 isDirty=false）。
    /// hotkey dirty 时顺路调 daemon 的 reloadHotkey() 让新组合立即生效
    func apply() {
        let hotkeyChanged = (config.hotkey != initial.hotkey)
        let restartNeeded = needsRestart
        do {
            try Config.write(config, to: configPath)
            initial = config
            if hotkeyChanged {
                AppDelegate.shared?.reloadHotkey()
            }
            statusMessage = restartNeeded
                ? "已应用 · 部分字段需重启 daemon 生效（用下方「立即重启」）"
                : "已应用 · 立即生效"
            statusIsError = false
        } catch {
            statusMessage = "写盘失败：\(error)"
            statusIsError = true
        }
    }

    /// 用户点「立即重启」时调用。`exit(0)` + launchd KeepAlive 自动 respawn
    func restartDaemon() {
        AppDelegate.shared?.restartDaemon()
    }

    /// 撤回到 baseline（取消未应用的修改）
    func discard() {
        config = initial
        statusMessage = nil
    }
}

// MARK: - 常规 tab

private struct GeneralSettingsTab: View {
    @State private var model = SettingsModel()

    // **关键 bug fix**：原版 body 在 `var body: some View` 里写了 `Form{}.formStyle(...)` 后
    // 紧跟一行 `applyBar`——SwiftUI @ViewBuilder 把它们打包成 TupleView，TabView 又把
    // TupleView 的每个子 View 当成独立 tab 渲染，所以会看到 5 个 tab。必须用 VStack 显式包
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("快捷键") {
                    LabeledContent("键位") {
                        TextField("", text: $model.config.hotkey.key)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .help("单个字符：A-Z / 0-9 / 标点 \\ ; ' , . / [ ] = - `")
                    }
                    LabeledContent("修饰键") {
                        HStack(spacing: 8) {
                            modifierToggle("⌘", name: "cmd")
                            modifierToggle("⌥", name: "option")
                            modifierToggle("⌃", name: "control")
                            modifierToggle("⇧", name: "shift")
                        }
                    }
                    LabeledContent("当前组合") {
                        Text("\(modifiersHumanString)\(displayKey)")
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Section("存储模式") {
                    Picker("blob 同步策略", selection: $model.config.mesh.storageMode) {
                        Text("完整 mirror").tag(StorageMode.full)
                        Text("按需拉取").tag(StorageMode.optimized)
                    }
                    .pickerStyle(.segmented)
                    Text(model.config.mesh.storageMode == .full
                         ? "PullWorker 每轮顺路把对端 blob 字节拉到本机做完整副本。日用机推荐。"
                         : "只同步元数据；缩略图 / 预览 / 粘贴时按需 GET。给小盘备机 / iOS 用。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section("Mesh 同步") {
                    Toggle("启用 mesh 同步", isOn: $model.config.mesh.enabled)
                    Toggle("启用 WebSocket 实时通知", isOn: $model.config.mesh.wsEnabled)
                    LabeledContent("Pull 周期") {
                        Stepper(value: $model.config.mesh.pullIntervalSec, in: 5...600, step: 5) {
                            Text("\(model.config.mesh.pullIntervalSec) 秒").monospacedDigit()
                        }
                    }
                }
                Section("捕获守门") {
                    LabeledContent("blob 上限") {
                        Stepper(value: blobMBBinding, in: 1...512) {
                            Text("\(blobMBBinding.wrappedValue) MB").monospacedDigit()
                        }
                    }
                    LabeledContent("文本上限") {
                        Stepper(value: textKBBinding, in: 1...8192, step: 16) {
                            Text("\(textKBBinding.wrappedValue) KB").monospacedDigit()
                        }
                    }
                    Text("超过 → capture 跳过入库，剪贴板本身仍可 Cmd+V 粘贴。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            ApplyBar(model: model)
        }
    }

    /// 单个修饰键 toggle——pill 样式跟 hotkey 心智一致，比一行一个 Toggle 紧凑
    private func modifierToggle(_ glyph: String, name: String) -> some View {
        let isOn = modifierBinding(name)
        return Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(glyph)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOn.wrappedValue
                              ? Color.accentColor
                              : Color.primary.opacity(0.08))
                )
                .foregroundStyle(isOn.wrappedValue ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func modifierBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { model.config.hotkey.modifiers.contains(name) },
            set: { isOn in
                var set = Set(model.config.hotkey.modifiers)
                if isOn { set.insert(name) } else { set.remove(name) }
                // 维持稳定顺序：cmd > option > control > shift
                let order = ["cmd", "option", "control", "shift"]
                model.config.hotkey.modifiers = order.filter { set.contains($0) }
            }
        )
    }

    /// 字母 uppercase 显示更醒目（"V" 而不是 "v"），标点保持原样
    private var displayKey: String {
        let k = model.config.hotkey.key
        if k.count == 1, let c = k.first, c.isLetter {
            return k.uppercased()
        }
        return k
    }

    private var modifiersHumanString: String {
        model.config.hotkey.modifiers.map { m -> String in
            switch m.lowercased() {
            case "cmd", "command": return "⌘"
            case "option", "alt": return "⌥"
            case "control", "ctrl": return "⌃"
            case "shift": return "⇧"
            default: return m
            }
        }.joined()
    }

    private var blobMBBinding: Binding<Int> {
        Binding(
            get: { model.config.capture.maxBlobBytes / (1024 * 1024) },
            set: { model.config.capture.maxBlobBytes = max(1, $0) * 1024 * 1024 }
        )
    }

    private var textKBBinding: Binding<Int> {
        Binding(
            get: { model.config.capture.maxTextBytes / 1024 },
            set: { model.config.capture.maxTextBytes = max(1, $0) * 1024 }
        )
    }
}

// MARK: - OCR tab

private struct OCRSettingsTab: View {
    @State private var model = SettingsModel()
    @State private var languagesText: String

    init() {
        let paths = Paths.makeDefault()
        let cfg = (try? Config.load(from: paths.configFile)) ?? .default
        _languagesText = State(initialValue: cfg.ocr.languages.joined(separator: ", "))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("OCR 索引") {
                    Toggle("启用 OCR (把图片里的文字写进搜索索引)", isOn: $model.config.ocr.enabled)
                    Picker("识别精度", selection: $model.config.ocr.recognitionLevel) {
                        Text("accurate (默认)").tag("accurate")
                        Text("fast").tag("fast")
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("单图字节上限") {
                        Stepper(value: $model.config.ocr.maxBlobMB, in: 1...128) {
                            Text("\(model.config.ocr.maxBlobMB) MB").monospacedDigit()
                        }
                    }
                    Text("超过上限 → 标 skipped 不喂 Vision。默认 16MB。fast 中文易漏字。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section("识别语言") {
                    TextField("逗号分隔，按优先级排", text: $languagesText)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: languagesText) { _, newValue in
                            model.config.ocr.languages = newValue
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                        }
                    Text("Vision recognitionLanguages hint。常用：zh-Hans, en-US, ja-JP")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            ApplyBar(model: model, onDiscard: {
                languagesText = model.config.ocr.languages.joined(separator: ", ")
            })
        }
    }
}

/// 共用 apply/discard 底栏。**必须**抽出来——把 Form 跟 ApplyBar 直接写在 tab body 里会
/// 让 SwiftUI @ViewBuilder 把它们打包成 TupleView，TabView 误判每个子 View 是独立 tab，
/// 视觉上 tab 数翻倍。tab body 用 VStack 显式包 Form + ApplyBar 才正确
private struct ApplyBar: View {
    @Bindable var model: SettingsModel
    /// OCR tab 的 discard 路径要顺路把 languagesText state 重置——通过闭包注入
    var onDiscard: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            if let msg = model.statusMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(model.statusIsError ? Color.red : Color.green)
                    .lineLimit(2)
            }
            Spacer()
            // apply 后如果还有未生效的非 hotkey 字段，提供一键重启按钮——比让用户去敲
            // `launchctl kickstart -k gui/$UID/io.duopaste.agent` 友好
            if !model.isDirty && model.statusMessage != nil && needsRestartHint {
                Button("立即重启") { model.restartDaemon() }
                    .buttonStyle(.bordered)
            }
            Button("撤回") {
                model.discard()
                onDiscard()
            }
            .disabled(!model.isDirty)
            Button("应用") { model.apply() }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(!model.isDirty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    /// statusMessage 含「重启」时才显示重启按钮——简单文本探测，避免引入新字段
    private var needsRestartHint: Bool {
        model.statusMessage?.contains("重启") ?? false
    }
}

// MARK: - 关于 tab

private struct AboutSettingsTab: View {
    @State private var fetchInProgress = false
    @State private var fetchReport: String?
    @State private var fetchIsError: Bool = false
    /// blob 仓库占用——nil 表示尚未算出 / 计算失败。
    /// onAppear / fetch-missing 完成后异步刷新
    @State private var blobsTotalBytes: Int64?
    /// blob 仓库所在卷可用空间。同上，按需异步刷
    @State private var diskAvailableBytes: Int64?

    var body: some View {
        Form {
            Section("进程") {
                LabeledContent("应用", value: "duo-paste")
                LabeledContent("Device ID", value: deviceIDDisplay)
                LabeledContent("拓扑", value: modeSummary)
                LabeledContent("存储模式", value: storageModeDisplay)
            }
            Section("Peers") {
                if peerList.isEmpty {
                    Text("未配置 peer（standalone 模式）").foregroundStyle(.secondary)
                } else {
                    ForEach(peerList, id: \.self) { entry in
                        Text(entry).font(.caption.monospaced())
                    }
                }
            }
            Section("Blob 补齐") {
                HStack(spacing: 8) {
                    Button {
                        runFetchMissing()
                    } label: {
                        if fetchInProgress {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.small)
                                Text("拉取中…")
                            }
                        } else {
                            Text("补齐缺失 blob")
                        }
                    }
                    .disabled(fetchInProgress || AppDelegate.shared?.dependencies == nil)
                    Spacer()
                }
                if let r = fetchReport {
                    Text(r).font(.caption)
                        .foregroundStyle(fetchIsError ? Color.red : Color.green)
                }
                Text("扫所有 peer-origin 缺字节的 image/file → 并发 GET /blob 拉回。等价 CLI `mesh-fetch-missing`。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("存储") {
                LabeledContent("Blob 仓库占用",
                              value: blobsTotalBytes.map(Self.formatBytes) ?? "计算中…")
                LabeledContent("磁盘可用",
                              value: diskAvailableBytes.map(Self.formatBytes) ?? "—")
                Text("可用 < 5 GB 时自动驱逐最老的非 pinned blob 文件到 10 GB；text / pinned / OCR 提取文本始终保留。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("路径") {
                let paths = Paths.makeDefault()
                LabeledContent("Config", value: paths.configFile.path)
                LabeledContent("数据库", value: paths.mainDB.path)
                LabeledContent("Blob 仓库", value: paths.blobsDir.path)
            }
        }
        .formStyle(.grouped)
        .task { await refreshStorageStats() }
    }

    /// 后台算 blob 总占用 + 卷可用空间。10k+ blob 走 enumerator < 1s，但仍异步跑不卡 UI
    private func refreshStorageStats() async {
        let blobsDir = Paths.makeDefault().blobsDir
        let (total, avail) = await Task.detached {
            (Volume.directorySize(at: blobsDir), Volume.availableBytes(at: blobsDir))
        }.value
        blobsTotalBytes = total
        diskAvailableBytes = avail
    }

    /// ByteCountFormatter `.file` style，1.2 GB / 487 MB 风格
    private static func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    private var deviceIDDisplay: String {
        AppDelegate.shared?.dependencies?.deviceID ?? "（daemon 未启动）"
    }

    private var modeSummary: String {
        AppDelegate.shared?.dependencies?.config.summary ?? "（daemon 未启动）"
    }

    private var storageModeDisplay: String {
        guard let m = AppDelegate.shared?.dependencies?.config.mesh.storageMode else {
            return "—"
        }
        return m.description
    }

    private var peerList: [String] {
        AppDelegate.shared?.dependencies?.config.peers.map { p -> String in
            let did = p.deviceID ?? "(learn)"
            return "\(p.url.absoluteString) · \(did)"
        } ?? []
    }

    private func runFetchMissing() {
        guard let deps = AppDelegate.shared?.dependencies, !fetchInProgress else { return }
        fetchInProgress = true
        fetchReport = nil
        let blobs = deps.blobs
        let deviceID = deps.deviceID
        let dbPath = deps.paths.mainDB
        let peerURLs = deps.config.peers.map { $0.url }
        let sharedSecretFile = deps.paths.sharedSecretFile
        Task { @MainActor in
            defer { fetchInProgress = false }
            if peerURLs.isEmpty {
                fetchReport = "未配置 peer，无法补齐"
                fetchIsError = true
                return
            }
            let secret: Data
            do {
                secret = try SharedSecret.load(from: sharedSecretFile)
            } catch {
                fetchReport = "shared-secret 加载失败：\(error)"
                fetchIsError = true
                return
            }
            let auth = HMACAuth(secret: secret)
            let clients = peerURLs.map { HTTPPeerClient(baseURL: $0, auth: auth) }
            let fetcher: @Sendable (String) async -> Admin.BlobFetchOutcome = { sha in
                var lastErr: Admin.BlobFetchOutcome = .notFound
                for c in clients {
                    do {
                        let r = try await c.getBlob(sha256: sha)
                        switch r {
                        case .found(let data): return .found(data)
                        case .notFound: lastErr = .notFound
                        }
                    } catch let e as GetBlobError {
                        switch e {
                        case .rejected(let reason): lastErr = .rejected(reason: reason)
                        case .shaMismatch(let exp, let act): lastErr = .shaMismatch(expected: exp, actual: act)
                        case .transient(let reason): lastErr = .transient(reason: reason)
                        }
                    } catch {
                        lastErr = .transient(reason: "\(error)")
                    }
                }
                return lastErr
            }
            FileHandle.standardError.write(Data("fetch-missing: 开始扫描\n".utf8))
            do {
                let report = try await Admin.fetchMissingBlobs(
                    dbPath: dbPath,
                    selfDeviceID: deviceID,
                    blobs: blobs,
                    fetcher: fetcher,
                    concurrency: 4,
                    log: { msg in
                        // 透传到 daemon stderr 让 `tail -f duo-pasted.err.log` 能看到进度
                        FileHandle.standardError.write(Data("fetch-missing: \(msg)\n".utf8))
                    }
                )
                FileHandle.standardError.write(Data(
                    "fetch-missing: done total=\(report.totalMissing) fetched=\(report.fetched) failed=\(report.failed)\n".utf8
                ))
                fetchReport = "扫到 \(report.totalMissing) 个缺失 · 拉到 \(report.fetched) · 失败 \(report.failed)"
                fetchIsError = report.failed > 0
                // 拉到字节后清缩略图缓存 + bump pulse 让 SearchView 卡片重渲。
                // 没这两步用户会看到「拉到 N」但卡片仍是占位（缓存陈旧）
                if report.fetched > 0 {
                    ImageThumbnailCache.shared.invalidateAll()
                    AppDelegate.shared?.state.blobInventoryPulse &+= 1
                    // 字节落盘 → blob 占用变了，刷新展示
                    await refreshStorageStats()
                }
            } catch {
                fetchReport = "执行失败：\(error)"
                fetchIsError = true
            }
        }
    }
}
