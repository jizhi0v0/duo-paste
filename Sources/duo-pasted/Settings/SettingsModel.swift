import SwiftUI
import AppKit
import DuoPasteCore
import DuoPasteSync

@MainActor
@Observable
final class SettingsModel {
    let configPath: URL
    var config: Config
    private(set) var initial: Config
    var statusMessage: String?
    var statusIsError = false
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private var cachedQRImage: NSImage?
    @ObservationIgnored private var cachedQRFingerprint: String?
    @ObservationIgnored private var qrPrewarmTask: Task<Void, Never>?
    @ObservationIgnored private var cachedPIN: String?
    @ObservationIgnored private var cachedPINGeneratedAt: Date?
    @ObservationIgnored private var cachedPINLifetimeSec: Int = 0
    @ObservationIgnored private var pinPrewarmTask: Task<Void, Never>?

    /// 复用 prewarm PIN 时的安全阈值:剩 < 这个秒数就丢弃 cache,让 sheet 现场重生成。
    /// 防"sheet 一开就过期"的糟糕体感(prewarm 跟 sheet 开启可能间隔很久)
    private static let pinReuseFreshnessSec = 5

    init() {
        let paths = Paths.makeDefault()
        self.configPath = paths.configFile
        let cfg = (try? Config.load(from: paths.configFile)) ?? .default
        self.config = cfg
        self.initial = cfg
        // Settings 窗口构造瞬间起后台 task 生成 QR/PIN cache,等用户切到 iOS 配对 tab
        // → 点"显示配对码"时 sheet 直接拿 cache,跳过 CIContext 启动 + actor hop
        prewarmPairingQR()
        prewarmPIN()
    }

    /// 当前 config 对应的 QR 图。fingerprint 不匹配则现场生成 + 更新 cache(同步 ~10ms)
    func pairingQRImage() -> NSImage? {
        let fp = PairingQR.fingerprint(for: config)
        if let img = cachedQRImage, cachedQRFingerprint == fp { return img }
        let img = PairingQR.generate(config: config)
        cachedQRImage = img
        cachedQRFingerprint = fp
        return img
    }

    var pairingChannelBindingReady: Bool {
        PairingQR.payload(config: config) != nil
    }

    /// 后台预生成 QR cache,非阻塞。idempotent——重复调用如果 fingerprint 一致直接返回
    func prewarmPairingQR() {
        let cfg = config
        let fp = PairingQR.fingerprint(for: cfg)
        if cachedQRFingerprint == fp, cachedQRImage != nil { return }
        qrPrewarmTask?.cancel()
        qrPrewarmTask = Task.detached(priority: .utility) { [weak self] in
            let img = PairingQR.generate(config: cfg)
            await MainActor.run {
                guard let self else { return }
                self.cachedQRImage = img
                self.cachedQRFingerprint = fp
            }
        }
    }

    /// 后台预生成 PIN session。PairingService.generatePIN 顶掉之前 active session,
    /// 所以重复调用安全。sheet 关掉后再 prewarm 一次让连续开关都瞬间显示
    func prewarmPIN() {
        pinPrewarmTask?.cancel()
        guard pairingChannelBindingReady else { return }
        pinPrewarmTask = Task { @MainActor [weak self] in
            guard let service = AppDelegate.shared?.pairingService else { return }
            let (pin, sec) = await service.generatePIN()
            guard let self else { return }
            self.cachedPIN = pin
            self.cachedPINLifetimeSec = sec
            self.cachedPINGeneratedAt = Date()
        }
    }

    /// sheet init 时调用,一次性消费 prewarm PIN(剩余时间够新鲜才返回)。
    /// 返回值含真实剩余秒数 + 生成时间(用作 sessionStartedAt 让 polling 配对成功判定正确)
    func consumePrewarmedPIN() -> (pin: String, secondsLeft: Int, generatedAt: Date)? {
        guard let pin = cachedPIN, let genAt = cachedPINGeneratedAt else { return nil }
        let elapsed = Int(Date().timeIntervalSince(genAt))
        let remaining = cachedPINLifetimeSec - elapsed
        // 太接近过期就丢弃 cache,让 sheet 走 generatePIN 现场创建新 session
        guard remaining >= Self.pinReuseFreshnessSec else {
            cachedPIN = nil
            cachedPINGeneratedAt = nil
            return nil
        }
        let result = (pin, remaining, genAt)
        // 一次性消费——sheet 关掉重开必须重新 prewarm
        cachedPIN = nil
        cachedPINGeneratedAt = nil
        return result
    }

    var isDirty: Bool { config != initial }

    var needsRestart: Bool {
        guard isDirty else { return false }
        var a = config
        var b = initial
        a.hotkey = initial.hotkey
        // 排除列表由 watcher + CaptureService 双 gate 热重载，不需要重启。
        a.capture.excludedBundleIDs = initial.capture.excludedBundleIDs
        b.capture.excludedBundleIDs = initial.capture.excludedBundleIDs
        return a != b
    }

    func apply() {
        let hotkeyChanged = config.hotkey != initial.hotkey
        let captureExclusionsChanged = config.capture.excludedBundleIDs != initial.capture.excludedBundleIDs
        let restartNeeded = needsRestart
        do {
            try Config.write(config, to: configPath)
            initial = config
            if hotkeyChanged {
                AppDelegate.shared?.reloadHotkey()
            }
            if captureExclusionsChanged {
                AppDelegate.shared?.reloadCapturePolicy()
            }
            statusMessage = restartNeeded ? "已应用 · 部分字段需重启 daemon 生效" : "已应用 · 立即生效"
            statusIsError = false
            // 需重启的提示 / 错误都让"重启"按钮 / 错误信息一直可见,不自动消失
            scheduleStatusDismiss(skip: restartNeeded)
        } catch {
            statusMessage = "写盘失败：\(error)"
            statusIsError = true
            cancelStatusDismiss()
        }
    }

    func discard() {
        cancelStatusDismiss()
        config = initial
        statusMessage = nil
        statusIsError = false
    }

    /// SettingsDetail 在 isDirty 由 false 变 true 那一刻调——用户开始新一轮编辑,
    /// 上次的"已应用"提示立刻收起 + cancel 还没触发的清除 timer。否则 timer 后续
    /// fire 会把用户新编辑期间的 statusMessage(若有)误清
    func notifyConfigEdited() {
        cancelStatusDismiss()
        if statusMessage != nil {
            statusMessage = nil
            statusIsError = false
        }
    }

    func restartDaemon() {
        AppDelegate.shared?.restartDaemon()
    }

    @discardableResult
    func addExcludedBundleID(_ raw: String) -> Bool {
        let bundleID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty,
              !bundleID.contains(where: { $0.isWhitespace }),
              !config.capture.excludedBundleIDs.contains(where: {
                  $0.caseInsensitiveCompare(bundleID) == .orderedSame
              })
        else { return false }
        config.capture.excludedBundleIDs.append(bundleID)
        config.capture.excludedBundleIDs.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return true
    }

    func removeExcludedBundleID(_ bundleID: String) {
        config.capture.excludedBundleIDs.removeAll {
            $0.caseInsensitiveCompare(bundleID) == .orderedSame
        }
    }

    // MARK: - OCR 队列状态 + 操作

    /// 本机 OCR 队列分布。nil = 还没读 / 没有 daemon 上下文。OCRPane .task 启动周期刷新
    var ocrStats: Admin.OCRStats?
    /// rebuild / abort 正在跑——按钮禁用,避免双击
    var ocrActionInFlight = false
    /// 上次操作结果(成功条数 / 失败原因);跟 statusMessage 独立,放 OCR pane 内
    var ocrActionMessage: String?
    var ocrActionIsError = false
    @ObservationIgnored private var ocrStatsRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var ocrActionMessageDismissTask: Task<Void, Never>?

    /// OCRPane .task { } 调起一次,popover 周期 tick 直到 view 消失
    func startOCRStatsTicker() {
        guard ocrStatsRefreshTask == nil else { return }
        ocrStatsRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refreshOCRStatsSync()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopOCRStatsTicker() {
        ocrStatsRefreshTask?.cancel()
        ocrStatsRefreshTask = nil
    }

    /// 同步读 DB ——只本机 SQLite,微秒级,不需要 await
    private func refreshOCRStatsSync() {
        guard let deps = AppDelegate.shared?.dependencies else {
            ocrStats = nil
            return
        }
        do {
            ocrStats = try Admin.ocrStats(
                dbPath: deps.paths.mainDB,
                selfDeviceID: deps.deviceID
            )
        } catch {
            // 读失败不弹错——刷新本就是 best-effort,UI 显示"--"即可
            ocrStats = nil
        }
    }

    /// 重建本机 OCR 索引:done → pending,worker wake 立即开扫
    func rebuildOCRIndex() {
        guard let deps = AppDelegate.shared?.dependencies, !ocrActionInFlight else { return }
        ocrActionInFlight = true
        Task { @MainActor [weak self] in
            defer { self?.ocrActionInFlight = false }
            do {
                let n = try Admin.rebuildOCRIndex(
                    dbPath: deps.paths.mainDB,
                    selfDeviceID: deps.deviceID
                )
                AppDelegate.shared?.wakeOCRWorker()
                self?.setOCRActionMessage("已翻 \(n) 条 done → pending,worker 开始重 OCR", isError: false)
                self?.refreshOCRStatsSync()
            } catch {
                self?.setOCRActionMessage("重建失败:\(error)", isError: true)
            }
        }
    }

    /// 中止本机 OCR 队列:pending → skipped。日后想恢复跑 retry-failed-ocr 即可
    func abortOCRQueue() {
        guard let deps = AppDelegate.shared?.dependencies, !ocrActionInFlight else { return }
        ocrActionInFlight = true
        Task { @MainActor [weak self] in
            defer { self?.ocrActionInFlight = false }
            do {
                let n = try Admin.abortOCRQueue(
                    dbPath: deps.paths.mainDB,
                    selfDeviceID: deps.deviceID
                )
                // worker 下一 tick 自然 fetchPending 拿到空集 → 进 idle sleep,不需要 wake
                self?.setOCRActionMessage("已中止 \(n) 条 pending → skipped;`retry-failed-ocr` 可恢复", isError: false)
                self?.refreshOCRStatsSync()
            } catch {
                self?.setOCRActionMessage("中止失败:\(error)", isError: true)
            }
        }
    }

    private func setOCRActionMessage(_ msg: String, isError: Bool) {
        ocrActionMessage = msg
        ocrActionIsError = isError
        ocrActionMessageDismissTask?.cancel()
        ocrActionMessageDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            self.ocrActionMessage = nil
            self.ocrActionIsError = false
            self.ocrActionMessageDismissTask = nil
        }
    }

    /// 当前 dirty 字段里有没有动 OCR 相关——给 ApplyBar 判断要不要弹半致警告
    var ocrFieldsDirty: Bool {
        guard isDirty else { return false }
        return config.ocr != initial.ocr
    }

    private func scheduleStatusDismiss(skip: Bool) {
        cancelStatusDismiss()
        guard !skip else { return }
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, !Task.isCancelled else { return }
            self.statusMessage = nil
            self.statusIsError = false
            self.dismissTask = nil
        }
    }

    private func cancelStatusDismiss() {
        dismissTask?.cancel()
        dismissTask = nil
    }
}
