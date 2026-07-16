import SwiftUI
import AppKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import DuoPasteCore
import DuoPasteSync

/// macOS 26 原生 Settings 内容。Settings scene 托管窗口和标题栏，
/// TabView / Form / Section 跟随系统设置外观。
struct SettingsView: View {
    @State private var model = SettingsModel()
    @State private var pane: Pane = .general

    enum Pane: String, CaseIterable, Hashable, Identifiable {
        case general, ocr, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "常规"
            case .ocr: return "OCR"
            case .about: return "关于"
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .ocr: return "text.viewfinder"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        TabView(selection: $pane) {
            ForEach(Pane.allCases) { pane in
                SettingsDetail(
                    pane: pane,
                    model: model,
                    appState: AppDelegate.shared?.state
                )
                .tag(pane)
                .tabItem {
                    Label(pane.title, systemImage: pane.icon)
                }
            }
        }
        .frame(width: 760, height: 620)
    }
}

private struct SettingsDetail: View {
    let pane: SettingsView.Pane
    @Bindable var model: SettingsModel
    var appState: AppState?

    var body: some View {
        Group {
            switch pane {
            case .general: GeneralPane(model: model, appState: appState)
            case .ocr: OCRPane(model: model)
            case .about: AboutPane()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if pane != .about && (model.isDirty || model.statusMessage != nil) {
                ApplyBar(model: model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.18), value: model.isDirty)
        .animation(.smooth(duration: 0.18), value: model.statusMessage)
        .onChange(of: model.isDirty) { _, newValue in
            if newValue { model.notifyConfigEdited() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

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
        a.hotkey = initial.hotkey
        return a != initial
    }

    func apply() {
        let hotkeyChanged = config.hotkey != initial.hotkey
        let restartNeeded = needsRestart
        do {
            try Config.write(config, to: configPath)
            initial = config
            if hotkeyChanged {
                AppDelegate.shared?.reloadHotkey()
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

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        Section {
            content
        } header: {
            Text(title)
        }
    }
}

private struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var isFirst = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        LabeledContent {
            trailing
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct SettingsNoteRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsBlock<Content: View>: View {
    var isFirst = false
    @ViewBuilder var content: Content

    var body: some View {
        content
    }
}

private struct HotkeyRecorder: NSViewRepresentable {
    @Binding var config: Config.HotkeyConfig

    func makeNSView(context: Context) -> HotkeyRecorderField {
        let view = HotkeyRecorderField()
        view.onChange = { newValue in
            config = newValue
        }
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderField, context: Context) {
        nsView.config = config
        nsView.onChange = { newValue in
            config = newValue
        }
    }
}

private final class HotkeyRecorderField: NSView {
    var onChange: ((Config.HotkeyConfig) -> Void)?

    var config: Config.HotkeyConfig = .default {
        didSet { updateLabel() }
    }

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1

        label.alignment = .center
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateLabel()
        updateChrome(focused: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        updateChrome(focused: true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        updateChrome(focused: false)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let key = Self.keyString(from: event),
              Config.HotkeyConfig.supportedKeys.contains(key) else {
            NSSound.beep()
            return
        }
        let modifiers = Self.modifiers(from: event)
        guard modifiers.contains(where: { $0 != "shift" }) else {
            NSSound.beep()
            return
        }
        let newConfig = Config.HotkeyConfig(key: key, modifiers: modifiers)
        config = newConfig
        onChange?(newConfig)
        window?.makeFirstResponder(nil)
    }

    private func updateLabel() {
        label.stringValue = hotkeyDisplay(config)
    }

    private func updateChrome(focused: Bool) {
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.35).cgColor
        layer?.borderColor = (focused ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.borderWidth = focused ? 2 : 1
    }

    private static func keyString(from event: NSEvent) -> String? {
        guard let raw = event.charactersIgnoringModifiers, !raw.isEmpty else { return nil }
        let first = String(raw.prefix(1))
        return first.uppercased()
    }

    private static func modifiers(from event: NSEvent) -> [String] {
        let flags = event.modifierFlags
        var result: [String] = []
        if flags.contains(.command) { result.append("cmd") }
        if flags.contains(.option) { result.append("option") }
        if flags.contains(.control) { result.append("control") }
        if flags.contains(.shift) { result.append("shift") }
        return result
    }
}

private func hotkeyDisplay(_ config: Config.HotkeyConfig) -> String {
    let mods = config.modifiers.map { m -> String in
        switch m.lowercased() {
        case "cmd", "command": return "⌘"
        case "option", "alt": return "⌥"
        case "control", "ctrl": return "⌃"
        case "shift": return "⇧"
        default: return m
        }
    }.joined()
    return "\(mods)\(config.key.uppercased())"
}

private struct GeneralPane: View {
    @Bindable var model: SettingsModel
    var appState: AppState?

    var body: some View {
        Form {
            SettingsGroup(title: "快捷键") {
                SettingsRow(title: "快捷键",
                            subtitle: "点按后直接输入新的组合键",
                            isFirst: true) {
                    HotkeyRecorder(config: $model.config.hotkey)
                        .frame(width: 138, height: 28)
                }
            }

            if let appState {
                AccessibilityPermissionGroup(appState: appState)
            }

            SettingsGroup(title: "存储模式") {
                SettingsRow(title: "blob 同步策略", isFirst: true) {
                    HStack(spacing: 8) {
                        GlassChoiceButton(
                            title: "完整 mirror",
                            isSelected: model.config.mesh.storageMode == .full
                        ) {
                            model.config.mesh.storageMode = .full
                        }
                        GlassChoiceButton(
                            title: "按需拉取",
                            isSelected: model.config.mesh.storageMode == .optimized
                        ) {
                            model.config.mesh.storageMode = .optimized
                        }
                    }
                    .frame(width: 220)
                }
                SettingsNoteRow(
                    text: model.config.mesh.storageMode == .full
                        ? "PullWorker 每轮顺路把对端 blob 字节拉到本机做完整副本。日用机推荐。"
                        : "只同步元数据；缩略图 / 预览 / 粘贴时按需 GET。给小盘备机 / iOS 用。"
                )
            }

            SettingsGroup(title: "Mesh 同步") {
                SettingsRow(title: "启用 mesh 同步", isFirst: true) {
                    Toggle("", isOn: $model.config.mesh.enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SettingsRow(title: "启用 WebSocket 实时通知") {
                    Toggle("", isOn: $model.config.mesh.wsEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SettingsRow(title: "Pull 周期") {
                    Stepper(value: $model.config.mesh.pullIntervalSec, in: 5...600, step: 5) {
                        Text("\(model.config.mesh.pullIntervalSec) 秒").monospacedDigit()
                    }
                }
                SettingsNoteRow(text: "WebSocket 会在对端 cursor_advanced 时推送，目标是 < 1s 同步延迟。")
            }

            if let appState {
                TransportStatusGroup(appState: appState)
            }

            SettingsGroup(title: "捕获守门") {
                SettingsRow(title: "blob 上限", isFirst: true) {
                    Stepper(value: blobMBBinding, in: 1...512) {
                        Text("\(blobMBBinding.wrappedValue) MB").monospacedDigit()
                    }
                }
                SettingsRow(title: "文本上限") {
                    Stepper(value: textKBBinding, in: 1...8192, step: 16) {
                        Text("\(textKBBinding.wrappedValue) KB").monospacedDigit()
                    }
                }
                SettingsNoteRow(text: "超过上限时 capture 跳过入库，剪贴板本身仍可 Cmd+V 粘贴。")
            }

            IOSPairingGroup(model: model)
        }
        .formStyle(.grouped)
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

/// Accessibility 权限引导块。daemon 启动时 AppDelegate 抓一次 AXIsProcessTrusted 写到
/// appState.accessibilityTrusted;这里渲染状态 + "打开系统设置" + "重新检查" 按钮。
/// AX 没 KVO,用户去系统设置勾完得回到这点 "重新检查",或者重启 daemon
private struct AccessibilityPermissionGroup: View {
    @Bindable var appState: AppState

    var body: some View {
        SettingsGroup(title: "自动粘贴权限") {
            SettingsRow(title: "Accessibility",
                        subtitle: appState.accessibilityTrusted
                            ? "已授予 — 双击条目可直接粘到上一个输入框"
                            : "未授予 — pasteboard 仍会写好,需要切回原 app 自己 Cmd+V",
                        isFirst: true) {
                HStack(spacing: 8) {
                    if appState.accessibilityTrusted {
                        Text("✓")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.green)
                    } else {
                        GlassActionButton(title: "打开系统设置", isProminent: true) {
                            openAccessibilityPane()
                        }
                    }
                    GlassActionButton(title: "重新检查", isProminent: false) {
                        AppDelegate.shared?.refreshAccessibilityTrusted()
                    }
                }
            }
            SettingsNoteRow(text: "授权后 panel 会用 .nonactivatingPanel 保留你原来的输入框焦点,双击条目自动模拟 Cmd+V 粘进去。未授权时不阻塞,只是要自己 Cmd+V。")
        }
    }

    /// 打开"系统设置 → 隐私与安全性 → 辅助功能"。URL scheme 在 macOS 13+ 稳定;
    /// 即便系统设置 UI 改版,这个 URL 都跳到正确面板
    private func openAccessibilityPane() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

/// SmartTransport 实时状态——AppState.transports 由 MeshSupervisor 启动 + reconcile
/// 完后 push 进来。@Bindable 让 AppState.transports / transportsUpdatedAt 变化自动
/// 重新渲染本组件（@Observable 跟踪机制）
private struct TransportStatusGroup: View {
    @Bindable var appState: AppState

    var body: some View {
        SettingsGroup(title: "当前传输路径") {
            if appState.transports.isEmpty {
                SettingsRow(title: "状态", isFirst: true) {
                    Text("未连接 / 未配置 peer")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                SettingsNoteRow(text: "config.peers 为空 / mesh.enabled=false / shared-secret 加载失败时这里空。配置好 peer 重启 daemon 看效果。")
            } else {
                ForEach(Array(appState.transports.enumerated()), id: \.element.id) { idx, snapshot in
                    TransportPeerBlock(snapshot: snapshot, isFirst: idx == 0)
                }
                if let ts = appState.transportsUpdatedAt {
                    SettingsNoteRow(text: refreshNote(updatedAt: ts))
                }
            }
        }
    }

    private func refreshNote(updatedAt: Date) -> String {
        let elapsed = Int(Date().timeIntervalSince(updatedAt))
        let when: String
        if elapsed < 5 { when = "刚刚" }
        else if elapsed < 60 { when = "\(elapsed) 秒前" }
        else if elapsed < 3600 { when = "\(elapsed / 60) 分钟前" }
        else { when = "\(elapsed / 3600) 小时前" }
        return "上次决策刷新 \(when)。DNS 变化 / tailscale up-down 时 daemon 自动 reconcile 重选 transport。"
    }
}

/// 单 peer 块——头行 (peer + source) + 每条 candidate URL 一行小表格。
/// 表格里 chosen 行加 ✓ 标记 + 主色，其他灰；左侧 PONTE/TAILSCALE badge + host，右侧 RTT。
/// 让数据自身说话——两组 RTT 数字并排比对一眼能看出 tailscale 短包快但 ponte 被选，
/// 不需要解释文字
private struct TransportPeerBlock: View {
    let snapshot: AppState.TransportSnapshot
    let isFirst: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst {
                Divider().padding(.leading, 16).opacity(0.55)
            }
            // 头行
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("peer #\(snapshot.id + 1)")
                    .font(.system(size: 13, weight: .regular))
                if let source = sourceLabel {
                    Text(source)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
            // 每条 candidate 一行
            VStack(spacing: 4) {
                ForEach(candidates) { c in
                    CandidateRow(candidate: c, isChosen: c.host == snapshot.chosenHost)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    private var sourceLabel: String? {
        if let manual = snapshot.manualPullURL {
            return "手抄 pull_url=\(manual)"
        } else if let learned = snapshot.learnedPonteHost {
            return "自动学到 ponte_host=\(learned)"
        }
        return nil
    }

    /// 按"选中优先 → 其他 reachable (ASC) → 不可达"排
    private var candidates: [TransportCandidate] {
        let chosen = snapshot.chosenHost
        return snapshot.httpRttMs
            .map { host, ms in
                TransportCandidate(
                    host: host,
                    ms: ms,
                    kind: host.lowercased().hasSuffix(".sgponte") ? .ponte : .tailscale
                )
            }
            .sorted { a, b in
                if a.host == chosen { return true }
                if b.host == chosen { return false }
                let ar = a.ms < 0 ? Int64.max : a.ms
                let br = b.ms < 0 ? Int64.max : b.ms
                return ar < br
            }
    }
}

private struct TransportCandidate: Identifiable, Sendable {
    let host: String
    let ms: Int64
    let kind: AppState.TransportSnapshot.Kind
    var id: String { host }
}

/// 单条 candidate 行——左：✓ + badge + host，右：RTT。chosen 主色，其他 secondary
private struct CandidateRow: View {
    let candidate: TransportCandidate
    let isChosen: Bool

    var body: some View {
        HStack(spacing: 8) {
            // ✓ 占位让选中/未选中行左侧对齐
            Image(systemName: isChosen ? "checkmark" : "circle")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isChosen ? badgeColor : Color.secondary.opacity(0.5))
                .frame(width: 12, alignment: .center)
            badge
            Text(candidate.host)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isChosen ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(rttText)
                .font(.system(size: 11, weight: isChosen ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(rttColor)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isChosen ? badgeColor.opacity(0.08) : Color.clear)
        )
    }

    private var rttText: String {
        candidate.ms < 0 ? "不可达" : "\(candidate.ms) ms"
    }

    private var rttColor: Color {
        if candidate.ms < 0 { return .red }
        return isChosen ? .primary : .secondary
    }

    private var badgeColor: Color {
        candidate.kind == .ponte ? .green : .blue
    }

    @ViewBuilder private var badge: some View {
        let text = candidate.kind == .ponte ? "PONTE" : "TAILSCALE"
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(badgeColor.opacity(isChosen ? 0.20 : 0.12))
            )
            .foregroundStyle(badgeColor.opacity(isChosen ? 1.0 : 0.7))
    }
}

private struct OCRPane: View {
    @Bindable var model: SettingsModel
    @State private var isLanguagePickerPresented = false

    var body: some View {
        Form {
            SettingsGroup(title: "OCR 索引") {
                SettingsRow(title: "启用 OCR",
                            subtitle: "把图片里的文字写进搜索索引",
                            isFirst: true) {
                    Toggle("", isOn: $model.config.ocr.enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SettingsRow(title: "识别精度") {
                    HStack(spacing: 8) {
                        GlassChoiceButton(
                            title: "accurate（默认）",
                            isSelected: model.config.ocr.recognitionLevel == "accurate"
                        ) {
                            model.config.ocr.recognitionLevel = "accurate"
                        }
                        GlassChoiceButton(
                            title: "fast",
                            isSelected: model.config.ocr.recognitionLevel == "fast"
                        ) {
                            model.config.ocr.recognitionLevel = "fast"
                        }
                    }
                    .frame(width: 280)
                }
                SettingsRow(title: "单图字节上限") {
                    Stepper(value: $model.config.ocr.maxBlobMB, in: 1...128) {
                        Text("\(model.config.ocr.maxBlobMB) MB").monospacedDigit()
                    }
                }
                SettingsNoteRow(text: "超过上限会标记 skipped，不喂 Vision。默认 16MB；fast 中文易漏字。")
            }

            SettingsGroup(title: "识别语言") {
                SettingsRow(title: "语言", isFirst: true) {
                    Button {
                        isLanguagePickerPresented.toggle()
                    } label: {
                        HStack(spacing: 7) {
                            HStack(spacing: 4) {
                                ForEach(languageSummaryTokens.prefix(3), id: \.self) { token in
                                    Text(token)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill(Color.accentColor.opacity(0.16))
                                        )
                                }
                                if languageSummaryTokens.count > 3 {
                                    Text("+\(languageSummaryTokens.count - 3)")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: 160, alignment: .trailing)
                            .clipped()

                            Image(systemName: isLanguagePickerPresented ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 8)
                        .padding(.trailing, 7)
                        .padding(.vertical, 5)
                        .frame(maxWidth: 190, alignment: .trailing)
                    }
                    .modifier(NativeGlassButtonChrome(isProminent: false))
                    .popover(isPresented: $isLanguagePickerPresented, arrowEdge: .bottom) {
                        LanguageMultiSelectPopover(
                            options: OCRLanguageOption.allOptions,
                            selectedIDs: selectedLanguageIDs,
                            onToggle: toggleLanguage
                        )
                        .frame(width: 260)
                        .padding(10)
                    }
                }
                SettingsNoteRow(text: "来自本机 Vision 支持列表；可连续勾选多个语言，仍会自动检测语言。")
            }

            OCRIndexStatusGroup(model: model)
        }
        .formStyle(.grouped)
        .task(id: model.config.ocr.enabled) {
            // OCRPane 进场起 ticker，离场 / 切 pane 触发 task cancel 自动 stop
            model.startOCRStatsTicker()
            // task closure 退出时 SwiftUI 已 cancel task；显式 stop 让重启 ticker 幂等
            defer { model.stopOCRStatsTicker() }
            // hold——靠 cancellation 让 closure 退出
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private var selectedLanguageIDs: Set<String> {
        Set(model.config.ocr.languages)
    }

    private var languageSummary: String {
        languageSummaryTokens.joined(separator: ", ")
    }

    private var languageSummaryTokens: [String] {
        let selected = OCRLanguageOption.allOptions
            .filter { selectedLanguageIDs.contains($0.id) }
            .map(\.shortTitle)
        return selected.isEmpty ? ["选择"] : selected
    }

    private func toggleLanguage(_ id: String) {
        var ids = model.config.ocr.languages
        if let idx = ids.firstIndex(of: id) {
            guard ids.count > 1 else { return }
            ids.remove(at: idx)
        } else {
            ids.append(id)
        }
        model.config.ocr.languages = ids
    }
}

/// OCR pane 底部:本机索引状态(pending/done/skipped/failed 计数) + 重建/中止两个操作。
///
/// 设计选型(2026-05,跟 codex 共识):
/// - 已 done 行换语言/精度**不会**自动重做——配置只对增量生效。这个 group 让用户**看得见**
///   该事实(灰字"已完成 N 条使用原配置")并给"重建索引"按钮一键翻回 pending
/// - 中途用户改设置 + 重启,worker 用新 config 跑剩下队列 → 历史库半致状态;这里
///   显式接受,ApplyBar 在 ocr 字段 dirty + pending>0 时弹警告提示用户改完再 rebuild 对齐
/// - 中止用 pending → skipped(而非新增 cancelled 状态)——skipped 语义就是"本次不处理",
///   日后 `retry-failed-ocr` 一并恢复
private struct OCRIndexStatusGroup: View {
    @Bindable var model: SettingsModel

    var body: some View {
        SettingsGroup(title: "本机索引状态") {
            SettingsRow(title: "队列", subtitle: subtitleForQueue, isFirst: true) {
                Text(queueDisplay)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            SettingsBlock {
                HStack(spacing: 8) {
                    GlassActionButton(
                        title: "重建本机 OCR 索引",
                        isProminent: false,
                        isDisabled: !canRebuild
                    ) {
                        model.rebuildOCRIndex()
                    }
                    GlassActionButton(
                        title: "中止当前队列",
                        isProminent: false,
                        isDisabled: !canAbort
                    ) {
                        model.abortOCRQueue()
                    }
                    Spacer()
                }
                if let msg = model.ocrActionMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(model.ocrActionIsError ? Color.red : Color.green)
                        .padding(.top, 4)
                }
            }
            SettingsNoteRow(
                text: noteText
            )
        }
    }

    private var queueDisplay: String {
        guard let s = model.ocrStats else { return "--" }
        return "pending \(s.pending) · done \(s.done) · skipped \(s.skipped) · failed \(s.failed)"
    }

    private var subtitleForQueue: String? {
        guard let s = model.ocrStats else { return nil }
        if s.pending > 0 { return "正在处理 \(s.pending) 张" }
        if s.total == 0 { return "本机暂无图片" }
        return "队列空闲"
    }

    /// 至少有 done 行才能 rebuild(否则等于空操作)
    private var canRebuild: Bool {
        guard !model.ocrActionInFlight else { return false }
        guard let s = model.ocrStats else { return false }
        return s.done > 0
    }

    /// 队列有 pending 才能 abort
    private var canAbort: Bool {
        guard !model.ocrActionInFlight else { return false }
        guard let s = model.ocrStats else { return false }
        return s.pending > 0
    }

    private var noteText: String {
        let baseHint = "已完成 OCR 的图片使用当时的语言/精度配置;改语言或精度后需点重建,新配置才会作用到历史图片。skipped/failed 行可用 CLI `retry-failed-ocr` 恢复。"
        guard let s = model.ocrStats, s.done > 0 else { return baseHint }
        return "已完成 \(s.done) 条图片使用当时的语言/精度配置;改语言或精度后需点重建,新配置才会作用到这些历史图片。skipped/failed 行可用 CLI `retry-failed-ocr` 恢复。"
    }
}

private struct LanguageMultiSelectPopover: View {
    let options: [OCRLanguageOption]
    let selectedIDs: Set<String>
    let onToggle: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("识别语言")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(options) { option in
                        Button {
                            onToggle(option.id)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: selectedIDs.contains(option.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(selectedIDs.contains(option.id) ? Color.accentColor : Color.secondary)
                                Text(option.title)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 30)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selectedIDs.contains(option.id) ? Color.accentColor.opacity(0.12) : Color.clear)
                        )
                    }
                }
            }
            .frame(maxHeight: 260)
        }
    }
}

private struct OCRLanguageOption: Identifiable, Equatable {
    let id: String
    let title: String
    let shortTitle: String

    static let defaultOption = OCRLanguageOption(
        id: "zh-Hans",
        title: "简体中文 (zh-Hans)",
        shortTitle: "简中"
    )

    static var allOptions: [OCRLanguageOption] {
        let supported = supportedLanguages
        var options: [OCRLanguageOption] = [
            defaultOption,
            OCRLanguageOption(id: "en-US", title: "English (en-US)", shortTitle: "EN"),
            OCRLanguageOption(id: "zh-Hant", title: "繁體中文 (zh-Hant)", shortTitle: "繁中"),
            OCRLanguageOption(id: "ja-JP", title: "日本語 (ja-JP)", shortTitle: "日本語"),
            OCRLanguageOption(id: "ko-KR", title: "한국어 (ko-KR)", shortTitle: "한국어")
        ].filter { option in
            supported.contains(option.id)
        }

        for language in supported where !options.contains(where: { $0.id == language }) {
            options.append(OCRLanguageOption(
                id: language,
                title: languageDisplayName(language),
                shortTitle: language
            ))
        }
        return options
    }

    private static var supportedLanguages: [String] {
        let accurateRequest = VNRecognizeTextRequest()
        accurateRequest.recognitionLevel = .accurate
        let fastRequest = VNRecognizeTextRequest()
        fastRequest.recognitionLevel = .fast
        let accurate = (try? accurateRequest.supportedRecognitionLanguages()) ?? []
        let fast = (try? fastRequest.supportedRecognitionLanguages()) ?? []
        let union = Set(accurate).union(fast)
        if union.isEmpty {
            return ["zh-Hans", "en-US", "ja-JP"]
        }
        return union.sorted { languageDisplayName($0) < languageDisplayName($1) }
    }

    private static func languageDisplayName(_ code: String) -> String {
        let locale = Locale.current
        if let name = locale.localizedString(forIdentifier: code) {
            return "\(name) (\(code))"
        }
        return code
    }
}

private struct AboutPane: View {
    @State private var fetchInProgress = false
    @State private var showFetchProgress = false
    @State private var fetchReport: String?
    @State private var fetchIsError = false
    @State private var fetchCooldownUntil: Date?
    @State private var blobsTotalBytes: Int64?
    @State private var diskAvailableBytes: Int64?
    @State private var checkTick = 0   // bump 后让「上次检查」字符串重算（见 lastUpdateCheckString）

    var body: some View {
        Form {
            SettingsGroup(title: "进程") {
                SettingsRow(title: "应用", isFirst: true) {
                    Text("duo-paste").foregroundStyle(.secondary)
                }
                SettingsRow(title: "Device ID") {
                    Text(deviceIDDisplay)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                SettingsRow(title: "拓扑") {
                    Text(modeSummary).foregroundStyle(.secondary)
                }
                SettingsRow(title: "存储模式") {
                    Text(storageModeDisplay).foregroundStyle(.secondary)
                }
            }

            // 软件更新——仅当 bundle 嵌了 Sparkle（SUFeedURL 存在）才显。DP_NO_SPARKLE
            // 本地构建不写 SU 键、不实例化 UpdaterController，这里不能碰 .shared
            if sparkleEnabled {
                SettingsGroup(title: "软件更新") {
                    SettingsBlock(isFirst: true) {
                        HStack {
                            Text(lastUpdateCheckString)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            Spacer()
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
                    }
                    SettingsRow(title: "接收测试版（beta）",
                                subtitle: "打开后更新到 beta channel 的预发布版本；关闭只跟 stable") {
                        Toggle("", isOn: Binding(
                            get: { UpdaterController.shared.includePrereleases },
                            set: { UpdaterController.shared.includePrereleases = $0 }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }
            }

            SettingsGroup(title: "Blob 补齐") {
                SettingsBlock(isFirst: true) {
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
                            .padding(.top, 4)
                    }
                }
                SettingsNoteRow(text: "扫所有 peer-origin 缺字节的 image/file → 并发 GET /blob 拉回。等价 CLI `mesh-fetch-missing`。")
            }

            SettingsGroup(title: "存储") {
                SettingsRow(title: "Blob 仓库占用", isFirst: true) {
                    Text(blobsTotalBytes.map(Self.formatBytes) ?? "计算中…")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                SettingsRow(title: "磁盘可用") {
                    Text(diskAvailableBytes.map(Self.formatBytes) ?? "—")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                SettingsNoteRow(text: "可用 < 5 GB 时自动驱逐最老的非 pinned blob 文件到 10 GB；text / pinned / OCR 提取文本始终保留。")
            }

            SettingsGroup(title: "路径") {
                let paths = Paths.makeDefault()
                pathRow("Config", path: paths.configFile.path, isFirst: true)
                pathRow("数据库", path: paths.mainDB.path)
                pathRow("Blob 仓库", path: paths.blobsDir.path)
            }
        }
        .formStyle(.grouped)
        .task { await subscribeStorageStats() }
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

    private func pathRow(_ title: String, path: String, isFirst: Bool = false) -> some View {
        SettingsRow(title: title, isFirst: isFirst) {
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

private struct PathChip: View {
    let path: String

    var body: some View {
        HStack(spacing: 6) {
            Text(compactPath)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 18, height: 18)
            }
            .modifier(NativeGlassButtonChrome(isProminent: false))
            .foregroundStyle(Color.secondary)
            .help("在 Finder 中显示")
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        )
        .help(path)
    }

    private var compactPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let display = path.hasPrefix(home)
            ? "~" + path.dropFirst(home.count)
            : path
        guard display.count > 44 else { return display }

        let parts = display.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let duoIndex = parts.lastIndex(of: "duo-paste") else {
            return "…/" + parts.suffix(3).joined(separator: "/")
        }
        let tail = parts.suffix(from: duoIndex).joined(separator: "/")
        return "~/…/" + tail
    }
}

private struct ApplyBar: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showOCRHalfConsistencyWarning {
                Text(ocrHalfConsistencyWarningText)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            HStack(spacing: 8) {
                if let msg = model.statusMessage {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(model.statusIsError ? Color.red : Color.green)
                        .lineLimit(2)
                }
                if !model.isDirty && model.statusMessage != nil && needsRestartHint {
                    GlassActionButton(title: "重启", isProminent: false) { model.restartDaemon() }
                }
                GlassActionButton(title: "恢复", isProminent: false, isDisabled: !model.isDirty) { model.discard() }
                GlassActionButton(title: "应用", isProminent: true, isDisabled: !model.isDirty) { model.apply() }
                    .keyboardShortcut(.return)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// OCR 字段 dirty 且本机已有 OCR 结果(pending 在跑 / done 历史)时弹警告。
    /// 用户改完语言/精度按"应用"前先看到提示。
    /// **必须**也覆盖 pending=0 / done>0 这条稳态——历史 done 仍按旧配置编出来,
    /// 改配置不会自动重 OCR,这才是 PR 要解决的核心半致状态。
    private var showOCRHalfConsistencyWarning: Bool {
        guard model.ocrFieldsDirty else { return false }
        guard let s = model.ocrStats else { return false }
        return s.pending > 0 || s.done > 0
    }

    private var ocrHalfConsistencyWarningText: String {
        let pending = model.ocrStats?.pending ?? 0
        let done = model.ocrStats?.done ?? 0
        if pending > 0 {
            return "⚠ OCR 队列剩 \(pending) 张待处理(另有 \(done) 张历史已完成)。应用后 worker 会用新配置跑剩下的图片,历史已完成的图片保持旧配置 → 半致状态。建议先到「本机索引状态」点「中止当前队列」清场,应用并重启 daemon 后再点「重建本机 OCR 索引」对齐。"
        } else {
            return "⚠ 本机已有 \(done) 张 OCR 结果按旧配置生成。应用后新图片走新配置,历史结果保持旧配置 → 半致状态。建议应用并重启 daemon 后到「本机索引状态」点「重建本机 OCR 索引」让历史也对齐。"
        }
    }

    private var needsRestartHint: Bool {
        model.statusMessage?.contains("重启") ?? false
    }

}

private struct GlassActionButton: View {
    let title: String
    let isProminent: Bool
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .modifier(NativeGlassButtonChrome(isProminent: isProminent))
            .disabled(isDisabled)
    }
}

/// Settings 里所有独立 action button 的单点样式契约。macOS 26 直接使用系统
/// Liquid Glass button styles；旧系统只做编译 / 运行兼容 fallback。
private struct NativeGlassButtonChrome: ViewModifier {
    let isProminent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if isProminent {
                content
                    .buttonStyle(.glassProminent)
                    .tint(.accentColor)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            if isProminent {
                content
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
            } else {
                content.buttonStyle(.bordered)
            }
        }
    }
}

/// macOS 26 原生 Liquid Glass 二态选择按钮。两态始终使用同一个 `.glass(.regular)`
/// 样式，只切换 Glass tint；避免 `.glass` / `.glassProminent` 不同 intrinsic padding
/// 造成点击时按钮高度跳变。材质、按压、hover 全交给系统。
private struct GlassChoiceButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            button.buttonStyle(.glass(
                .regular.tint(isSelected ? Color.accentColor : nil)
            ))
        } else {
            button
                .buttonStyle(.bordered)
                .tint(isSelected ? Color.accentColor : nil)
        }
    }

    private var button: some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - iOS PIN 配对(Bonjour + PIN)

/// QR payload 不含 PIN(故意——QR 被截图 ≠ 配对失守,见 IOSPairingPINSheet 注释),所以
/// QR 内容只依赖 host/port/tls,可以脱离 sheet 生命周期常驻 SettingsModel cache
private enum PairingQR {
    /// 复用单例:每次 new CIContext 会启动 Metal device(~50-150ms)
    private static let ciContext = CIContext()

    static func fingerprint(for cfg: Config) -> String {
        "\(resolveHost(cfg: cfg))|\(cfg.servePort)|\(cfg.serveTLS)"
    }

    /// 选 host:tlsCertPath 文件 stem(Tailscale FQDN,跨 LAN 通) → fallback .local
    static func resolveHost(cfg: Config) -> String {
        if let cert = cfg.tlsCertPath {
            let stem = (cert as NSString).lastPathComponent
                .replacingOccurrences(of: ".crt", with: "")
            if !stem.isEmpty { return stem }
        }
        let hn = Host.current().localizedName ?? Host.current().name ?? "mac"
        return hn.hasSuffix(".local") ? hn : "\(hn).local"
    }

    /// 同步生成 QR 图——CIContext 复用后 ~10ms,可 detached task 调
    static func generate(config: Config) -> NSImage? {
        let payload: [String: Any] = [
            "host": resolveHost(cfg: config),
            "port": config.servePort,
            "tls": config.serveTLS,
            "v": 1,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return nil
        }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage else { return nil }
        let scale: CGFloat = 240 / ci.extent.width
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 240, height: 240))
    }
}

/// daemon 在 serve=true 时通过 BonjourAdvertiser 广播 `_duopaste._tcp`,iOS Settings
/// 端 NWBrowser 浏到本机后用户 tap → 输 6 位 PIN → POST /pair/<pin> 拿 secret + endpoints。
/// 60s expiry + 5 次错误封锁,PIN 用过即失效
@MainActor
private struct IOSPairingGroup: View {
    @Bindable var model: SettingsModel
    @State private var showPIN: Bool = false

    var body: some View {
        SettingsGroup(title: "iOS 配对") {
            SettingsRow(title: "广播状态", subtitle: model.config.serve
                        ? "本机 daemon serve=true → Bonjour 广播 _duopaste._tcp · iOS Settings 可见"
                        : "未开启 serve → iOS 看不到本机。先开 serve 再来配对",
                        isFirst: true) {
                Text(model.config.serve ? "ON" : "OFF")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.config.serve ? Color.green : Color.secondary)
            }
            SettingsRow(title: "PIN 配对") {
                GlassActionButton(title: "显示配对码", isProminent: true,
                                  isDisabled: !model.config.serve) {
                    showPIN = true
                }
                .controlSize(.small)
            }
            SettingsNoteRow(text: "iOS Settings 选「发现的 Mac」对应一行 → 输入这边显示的 6 位数字 → 自动获取 secret + 候选 endpoints。PIN 60s 失效,错 5 次封锁")
        }
        .sheet(isPresented: $showPIN) {
            IOSPairingPINSheet(model: model, isPresented: $showPIN)
        }
    }
}

// MARK: - PIN 配对 sheet

@MainActor
private struct IOSPairingPINSheet: View {
    let model: SettingsModel
    @Binding var isPresented: Bool

    @State private var pin: String?
    @State private var qrImage: NSImage?
    @State private var secondsLeft: Int = 0
    @State private var refreshTask: Task<Void, Never>?
    @State private var pollTask: Task<Void, Never>?
    @State private var sessionStartedAt: Date?
    @State private var paired: Bool = false
    @State private var errorText: String?

    init(model: SettingsModel, isPresented: Binding<Bool>) {
        self.model = model
        self._isPresented = isPresented
        // 关键:在 init 里给 @State 赋初值,让第一帧 body 求值时 qrImage/pin 已经有值。
        // 不能依赖 onAppear——onAppear 在第一帧渲染之后才触发,sheet 整个 modal
        // 动画(~350ms fade-in)过程中显示的会是 ProgressView,动画结束才"砰"出现
        self._qrImage = State(initialValue: model.pairingQRImage())
        // PIN cache 命中(剩余 >= 5s)就用 prewarm 的;否则保持 nil 让 onAppear 现场生成
        if let cached = model.consumePrewarmedPIN() {
            self._pin = State(initialValue: cached.pin)
            self._secondsLeft = State(initialValue: cached.secondsLeft)
            self._sessionStartedAt = State(initialValue: cached.generatedAt)
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(paired ? "配对成功 ✓" : "iOS 配对")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(paired ? Color.green : Color.primary)

            // 配对成功只显示绿色 checkmark 1.5s 后自动关
            if paired {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.green)
                    .frame(width: 260, height: 260)
            } else if let qrImage {
                // QR 码 — iOS 扫这个拿 host;PIN 用户手输让 QR 泄露 ≠ 配对失守
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: 260, height: 260)
                    .background(Color.white)
                    .padding(8)
            } else {
                // QR cache miss + 仍在生成:统一 spinner,不留空白窗格
                ProgressView().frame(width: 260, height: 260)
            }

            // PIN 文本(成功后隐藏)
            if !paired, let pin {
                VStack(spacing: 4) {
                    Text("PIN(扫码后输入)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(Array(pin), id: \.self) { ch in
                            Text(String(ch))
                                .font(.system(size: 22, weight: .bold, design: .monospaced))
                                .frame(width: 24, height: 34)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }

            if paired {
                Text("iOS 已拿到 secret + endpoints,正在连接…")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            } else if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else if pin == nil {
                // actor hop 完成前 secondsLeft=0 + pin=nil,不能落到"已过期"分支
                Text("正在生成…")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            } else if secondsLeft > 0 {
                Text("剩余 \(secondsLeft)s · iOS DuoPaste 扫这个 QR + 输上方 PIN")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
            } else {
                // 倒计时归零的瞬间——countdown task 立刻触发 generatePIN,文案保持
                // "正在刷新" 而非"已过期",防一帧闪烁
                Text("正在刷新…")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            }

            HStack(spacing: 12) {
                if !paired {
                    // 自动刷接管常规过期;按钮留给"PIN 看错想换一个"这种主动场景
                    Button("重新生成") {
                        generatePIN()
                    }
                    .modifier(NativeGlassButtonChrome(isProminent: false))
                    .controlSize(.small)
                    .disabled(pin == nil)
                }
                Button("关闭") {
                    // 只 dismiss,把 cancel + prewarm 留给 onDisappear 串行执行——
                    // 这里 fire-and-forget cancelPIN() 跟 onDisappear 起的独立 Task 同时排队到
                    // PairingService actor,顺序无保证。旧 cancel 排到新 prewarm 之后就会
                    // 作废刚 cache 的 PIN,下次开 sheet 可能拿到服务端已 cancel 的 PIN
                    isPresented = false
                }
                .modifier(NativeGlassButtonChrome(isProminent: true))
                .controlSize(.small)
                .keyboardShortcut(.escape)
            }
        }
        .padding(24)
        .frame(width: 320)
        .onAppear {
            // qrImage / pin 已在 init 从 cache 读;cache miss 时走兜底路径
            if qrImage == nil {
                qrImage = model.pairingQRImage()
            }
            if pin != nil, secondsLeft > 0 {
                // init 已经从 cache 拿到 PIN → 直接启 countdown + polling 跳过 actor hop
                startCountdown()
                startPollingForConsumption()
            } else {
                generatePIN()
            }
        }
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
            pollTask?.cancel()
            pollTask = nil
            qrImage = nil  // 防 secret-containing image 在 onDisappear 残留 memory
            // cancel + prewarm 必须串行:两者都派 Task 到 PairingService actor,
            // 独立 Task 的 actor 入队顺序无保证,可能让新生成的 PIN 被旧 cancel 干掉。
            // 串到一个 Task 里 await cancel 完成再 prewarm,actor 顺序自然保证
            Task { @MainActor in
                if let service = AppDelegate.shared?.pairingService {
                    await service.cancel()
                }
                model.prewarmPIN()
            }
        }
    }

    private func generatePIN() {
        guard let service = AppDelegate.shared?.pairingService else {
            errorText = "daemon 未启动或 pairing service 未配置"
            return
        }
        errorText = nil
        paired = false
        Task { @MainActor in
            let (newPin, sec) = await service.generatePIN()
            self.pin = newPin
            self.secondsLeft = sec
            self.sessionStartedAt = Date()
            // QR cache miss(prewarm 没赶上 / 配置变了)兜底现场生成
            if qrImage == nil {
                qrImage = model.pairingQRImage()
            }
            startCountdown()
            startPollingForConsumption()
        }
    }

    /// 周期 500ms poll PairingService.snapshot,session 没了 + 最近被消费过
    /// → 配对成功,显示 ✓ 1.5s 后自动关 sheet
    private func startPollingForConsumption() {
        pollTask?.cancel()
        let startedAt = sessionStartedAt
        pollTask = Task { @MainActor in
            while !Task.isCancelled, !paired {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let service = AppDelegate.shared?.pairingService else { continue }
                let snap = await service.snapshot()
                // session 已消失 + 这次 session 期间消费过 → 配对成功
                if !snap.active,
                   let consumed = snap.lastConsumed,
                   let started = startedAt,
                   consumed >= started {
                    paired = true
                    refreshTask?.cancel()
                    refreshTask = nil
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    isPresented = false
                    return
                }
            }
        }
    }

    private func startCountdown() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            while !Task.isCancelled, secondsLeft > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                self.secondsLeft -= 1
            }
            // 倒计时归零自动续 PIN——sheet 还开着 = 用户主观仍在等配对,跟
            // Continuity 配对码语义一致;PIN 60s TTL 边界不受削弱(每个 PIN 仍 60s 后失效)
            if !Task.isCancelled, !paired {
                generatePIN()
            }
        }
    }
}
