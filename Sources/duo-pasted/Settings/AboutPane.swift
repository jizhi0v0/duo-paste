import SwiftUI
import AppKit
import DuoPasteCore
import DuoPasteSync

/// 关于:进程信息、已配对设备、软件更新、TLS 证书、安全诊断、blob 补齐、存储与路径。
/// 纯只读页——没有可编辑 config,所以不挂 ApplyBar(见 `SettingsPane.editsConfig`)。
struct AboutPane: View {
    @State private var fetchInProgress = false
    @State private var showFetchProgress = false
    @State private var fetchReport: String?
    @State private var fetchIsError = false
    @State private var fetchCooldownUntil: Date?
    @State private var blobsTotalBytes: Int64?
    @State private var diskAvailableBytes: Int64?
    @State private var checkTick = 0   // bump 后让「上次检查」字符串重算（见 lastUpdateCheckString）
    @State private var tlsCertificateState: TLSCertificateState = .notConfigured
    @State private var deviceCredentials: [DeviceCredentialRecord] = []
    @State private var credentialLoadError: String?
    @State private var credentialRevokingID: String?

    var body: some View {
        SettingsPage(pane: .about) {
            processCard
            credentialsCard
            // 软件更新——仅当 bundle 嵌了 Sparkle（SUFeedURL 存在）才显。DP_NO_SPARKLE
            // 本地构建不写 SU 键、不实例化 UpdaterController，这里不能碰 .shared
            if sparkleEnabled { updateCard }
            tlsCard
            diagnosticsCard
            blobFetchCard
            storageCard
            pathsCard
        }
        .task {
            refreshTLSCertificate()
            await refreshDeviceCredentials()
            await subscribeStorageStats()
        }
    }

    // MARK: - 进程

    private var processCard: some View {
        SettingsCard(header: "进程") {
            SettingsField(title: "应用") {
                Text("duo-paste").foregroundStyle(.secondary)
            }
            SettingsDivider()
            SettingsField(title: "Device ID") {
                Text(deviceIDDisplay)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            SettingsDivider()
            SettingsField(title: "拓扑") {
                Text(modeSummary).foregroundStyle(.secondary)
            }
            SettingsDivider()
            SettingsField(title: "存储模式") {
                Text(storageModeDisplay).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 已配对设备

    private var credentialsCard: some View {
        SettingsCard(
            header: "已配对设备",
            footer: "撤销只影响这一份 iOS 凭据；其他 iOS 与 Mac mesh 继续可用。"
        ) {
            if deviceCredentials.isEmpty {
                SettingsField(title: "设备", detail: credentialLoadError) {
                    Text(credentialLoadError == nil ? "暂无独立凭据" : "读取失败")
                        .foregroundStyle(credentialLoadError == nil ? Color.secondary : Color.red)
                }
            } else {
                ForEach(Array(deviceCredentials.enumerated()), id: \.element.id) { index, record in
                    if index > 0 { SettingsDivider() }
                    SettingsField(
                        title: record.claims.displayName,
                        detail: credentialSubtitle(record)
                    ) {
                        if record.isRevoked {
                            Text("已撤销").foregroundStyle(.red)
                        } else {
                            GlassActionButton(
                                title: credentialRevokingID == record.id ? "撤销中…" : "撤销",
                                isProminent: false,
                                isDisabled: credentialRevokingID != nil
                            ) {
                                revokeCredential(record)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 软件更新

    private var updateCard: some View {
        SettingsCard(header: "软件更新") {
            HStack {
                Text(lastUpdateCheckString)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                GlassActionButton(title: "检查更新", isProminent: true) {
                    UpdaterController.shared.checkForUpdates()
                    // checkForUpdates 异步（Sparkle 弹窗 + 网络），lastUpdateCheckDate
                    // 检查完成后才更新。延迟 bump checkTick 让字符串重算捕获新日期；
                    // cosmetic——没捕获到也只是下次重渲再刷新。
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        checkTick &+= 1
                    }
                }
            }
            .settingsRow()
            SettingsDivider()
            SettingsToggleField(
                title: "接收测试版（beta）",
                detail: "打开后更新到 beta channel 的预发布版本；关闭只跟 stable",
                isOn: Binding(
                    get: { UpdaterController.shared.includePrereleases },
                    set: { UpdaterController.shared.includePrereleases = $0 }
                ))
        }
    }

    // MARK: - TLS 证书

    private var tlsCard: some View {
        SettingsCard(
            header: "TLS 证书",
            footer: "到期前 30 / 7 / 1 天逐级预警；mkcert leaf 不会自动续期。"
        ) {
            switch tlsCertificateState.state {
            case .notConfigured:
                SettingsField(title: "状态") {
                    Text("未启用 HTTPS").foregroundStyle(.secondary)
                }
            case .unreadable:
                SettingsField(
                    title: "状态",
                    detail: tlsCertificateState.error ?? "leaf certificate 无法解析"
                ) {
                    Text("无法读取").foregroundStyle(.red)
                }
            case .inspected:
                if let leaf = tlsCertificateState.leaf {
                    SettingsField(title: "状态") {
                        Text(tlsExpiryDisplay(leaf))
                            .foregroundStyle(tlsExpiryColor(leaf.expiryStatus))
                            .monospacedDigit()
                    }
                    SettingsDivider()
                    SettingsField(title: "到期日") {
                        Text(Self.certificateDateFormatter.string(from: leaf.notAfter))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    SettingsDivider()
                    SettingsField(title: "DNS SAN") {
                        Text(leaf.dnsSANs.isEmpty ? "(none)" : leaf.dnsSANs.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
            }
            SettingsDivider()
            HStack {
                Spacer()
                GlassActionButton(title: "重新检查", isProminent: false) {
                    refreshTLSCertificate()
                }
            }
            .settingsRow()
        }
    }

    // MARK: - 安全诊断

    private var diagnosticsCard: some View {
        SettingsCard(
            header: "安全诊断",
            footer: "固定排除 shared-secret、device credential/token、TLS 私钥、数据库/剪贴板正文、preview、blob 与缩略图字节。"
        ) {
            HStack {
                Text("mesh-doctor、quick_check、版本、脱敏 config 与白名单运维日志")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                GlassActionButton(title: "导出诊断包…", isProminent: false) {
                    AppDelegate.shared?.showDiagnosticExportDialog()
                }
            }
            .settingsRow()
        }
    }

    // MARK: - Blob 补齐

    private var blobFetchCard: some View {
        SettingsCard(
            header: "Blob 补齐",
            footer: "扫所有 peer-origin 缺字节的 image/file → 并发 GET /blob 拉回。等价 CLI `mesh-fetch-missing`。"
        ) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button {
                        runFetchMissing()
                    } label: {
                        if showFetchProgress {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("拉取中…")
                            }
                        } else if isFetchCoolingDown {
                            Text("无需补齐")
                        } else {
                            Text("补齐缺失 blob")
                        }
                    }
                    .modifier(NativeGlassButtonChrome(isProminent: false))
                    .disabled(fetchInProgress || isFetchCoolingDown || AppDelegate.shared?.dependencies == nil)
                    Spacer()
                }
                if let fetchReport {
                    Text(fetchReport)
                        .font(.caption)
                        .foregroundStyle(fetchIsError ? Color.red : Color.green)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
            }
            .settingsRow()
        }
    }

    // MARK: - 存储

    private var storageCard: some View {
        SettingsCard(
            header: "存储",
            footer: "可用 < 5 GB 时自动驱逐最老的非 pinned blob 文件到 10 GB；text / pinned / OCR 提取文本始终保留。"
        ) {
            SettingsField(title: "Blob 仓库占用") {
                Text(blobsTotalBytes.map(Self.formatBytes) ?? "计算中…")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            SettingsDivider()
            SettingsField(title: "磁盘可用") {
                Text(diskAvailableBytes.map(Self.formatBytes) ?? "—")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - 路径

    private var pathsCard: some View {
        let paths = Paths.makeDefault()
        return SettingsCard(header: "路径") {
            pathRow("Config", path: paths.configFile.path)
            SettingsDivider()
            pathRow("数据库", path: paths.mainDB.path)
            SettingsDivider()
            pathRow("Blob 仓库", path: paths.blobsDir.path)
        }
    }
    private var sparkleEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    private var lastUpdateCheckString: String {
        _ = checkTick   // 触发依赖追踪：checkTick 变 → SwiftUI 重算此字符串
        guard let d = UpdaterController.shared.lastUpdateCheckDate else {
            return "自动检查更新已开启"
        }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return "上次检查：\(fmt.string(from: d))"
    }

    private func pathRow(_ title: String, path: String) -> some View {
        SettingsField(title: title) {
            PathChip(path: path)
                .frame(maxWidth: 300, alignment: .trailing)
        }
    }

    /// 订阅 BlobStorageStats 推送 —— 任何 put/evict 都即时更新 `blobsTotalBytes`，
    /// 不再扫盘。`diskAvailableBytes` 只取首次（卷容量变化慢，且没有事件源）。view 消失
    /// 时 `.task` 自动 cancel → stream 的 onTermination 清理 continuation
    private func subscribeStorageStats() async {
        let blobsDir = Paths.makeDefault().blobsDir
        diskAvailableBytes = await Task.detached {
            Volume.availableBytes(at: blobsDir)
        }.value
        guard let stats = AppDelegate.shared?.dependencies?.blobStats else {
            // daemon 未启动 —— 兜底跑一次扫盘，UI 仍能看到数字
            blobsTotalBytes = await Task.detached {
                Volume.directorySize(at: blobsDir)
            }.value
            return
        }
        for await bytes in await stats.stream() {
            blobsTotalBytes = bytes
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    private var deviceIDDisplay: String {
        AppDelegate.shared?.dependencies?.deviceID ?? "(daemon 未启动)"
    }

    private var modeSummary: String {
        AppDelegate.shared?.dependencies?.config.summary ?? "(daemon 未启动)"
    }

    private var storageModeDisplay: String {
        AppDelegate.shared?.dependencies?.config.mesh.storageMode.description ?? "—"
    }

    private func refreshTLSCertificate() {
        guard let config = AppDelegate.shared?.dependencies?.config else {
            tlsCertificateState = .unreadable("daemon 未启动")
            return
        }
        tlsCertificateState = AppDelegate.tlsCertificateState(for: config)
    }

    private func refreshDeviceCredentials() async {
        do {
            deviceCredentials = try await AppDelegate.shared?.listDeviceCredentials() ?? []
            credentialLoadError = nil
        } catch {
            credentialLoadError = String(describing: error)
        }
    }

    private func revokeCredential(_ record: DeviceCredentialRecord) {
        guard credentialRevokingID == nil else { return }
        credentialRevokingID = record.id
        Task { @MainActor in
            defer { credentialRevokingID = nil }
            do {
                try await AppDelegate.shared?.revokeDeviceCredential(record.id)
                await refreshDeviceCredentials()
            } catch {
                credentialLoadError = "撤销失败：\(error)"
            }
        }
    }

    private func credentialSubtitle(_ record: DeviceCredentialRecord) -> String {
        let platform = record.claims.platform.uppercased()
        let lastActive: String
        if let ms = record.lastActiveAtMs {
            lastActive = "最后活跃 \(Self.credentialDateFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1_000)))"
        } else {
            lastActive = "尚未使用"
        }
        return "\(platform) · \(lastActive) · \(record.claims.deviceID)"
    }

    private static let credentialDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private func tlsExpiryDisplay(_ leaf: TLSCertificateReport) -> String {
        switch leaf.expiryStatus {
        case .valid:
            return "有效 · 剩余 \(leaf.daysRemaining) 天"
        case .expiresWithin30Days:
            return "⚠ 30 天内到期 · 剩余 \(leaf.daysRemaining) 天"
        case .expiresWithin7Days:
            return "⚠ 7 天内到期 · 剩余 \(leaf.daysRemaining) 天"
        case .expiresWithin1Day:
            return "⚠ 1 天内到期"
        case .expired:
            return "已过期"
        case .notYetValid:
            return "尚未生效"
        }
    }

    private func tlsExpiryColor(_ status: TLSCertificateReport.ExpiryStatus) -> Color {
        switch status {
        case .valid: .green
        case .expiresWithin30Days: .orange
        case .expiresWithin7Days, .expiresWithin1Day, .expired, .notYetValid: .red
        }
    }

    private static let certificateDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private func runFetchMissing() {
        guard let deps = AppDelegate.shared?.dependencies,
              !fetchInProgress,
              !isFetchCoolingDown else { return }
        fetchInProgress = true
        showFetchProgress = false
        let blobs = deps.blobs
        let deviceID = deps.deviceID
        let dbPath = deps.paths.mainDB
        let peerURLs = deps.config.peers.map { $0.effectivePullURL }
        let sharedSecretFile = deps.paths.sharedSecretFile
        Task { @MainActor in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(280))
                if fetchInProgress {
                    showFetchProgress = true
                }
            }
            defer {
                fetchInProgress = false
                showFetchProgress = false
            }
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
            let clients = peerURLs.map {
                HTTPPeerClient(
                    baseURL: $0,
                    auth: auth,
                    session: PonteSession.session(for: $0, fallback: AppDependencies.syncURLSession)
                )
            }
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
                        FileHandle.standardError.write(Data("fetch-missing: \(msg)\n".utf8))
                    }
                )
                FileHandle.standardError.write(Data(
                    "fetch-missing: done total=\(report.totalMissing) fetched=\(report.fetched) failed=\(report.failed)\n".utf8
                ))
                for failure in report.failures {
                    FileHandle.standardError.write(Data(
                        "fetch-missing: failure sha=\(failure.sha) reason=\(failure.reason)\n".utf8
                    ))
                }
                if report.totalMissing == 0 {
                    startFetchCooldown()
                    fetchReport = "没有缺失 blob"
                } else {
                    fetchReport = "扫到 \(report.totalMissing) 个缺失 · 拉到 \(report.fetched) · 失败 \(report.failed)"
                }
                fetchIsError = report.failed > 0
                if report.fetched > 0 {
                    ImageThumbnailCache.shared.invalidateAll()
                    AppDelegate.shared?.state.blobInventoryPulse &+= 1
                    // blobsTotalBytes 由 BlobStorageStats.stream 自动推 —— putVerified 经
                    // BlobStore.notifyAdded 喂 actor，订阅的 .task 会收到新值
                }
            } catch {
                fetchReport = "执行失败：\(error)"
                fetchIsError = true
            }
        }
    }

    private func startFetchCooldown() {
        fetchCooldownUntil = Date().addingTimeInterval(4)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            fetchCooldownUntil = nil
        }
    }

    private var isFetchCoolingDown: Bool {
        guard let until = fetchCooldownUntil else { return false }
        if Date() < until {
            return true
        }
        return false
    }
}
