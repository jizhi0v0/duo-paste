import SwiftUI
import AppKit
import Vision
import DuoPasteCore
import DuoPasteSync

/// Paste 风格 Settings：左侧自绘 sidebar，右侧标题 + 紧凑分组卡片。
/// SwiftUI Settings scene 在 accessory app 里不可靠，所以窗口仍由 AppDelegate 自管。
struct SettingsView: View {
    @State private var model = SettingsModel()
    @State private var pane: Pane = .general
    /// AppDelegate.showSettings 注入——给 GeneralPane 订阅 transports 状态用。
    /// nil = preview / 测试场景，UI 那块 transport 区降级为"未连接"提示
    var appState: AppState?

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
        HStack(spacing: 0) {
            Sidebar(pane: $pane)
                .frame(width: 220)
            SettingsDetail(pane: pane, model: model, appState: appState)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        .frame(minWidth: 700, idealWidth: 760, minHeight: 560, idealHeight: 620)
    }
}

private struct Sidebar: View {
    @Binding var pane: SettingsView.Pane

    var body: some View {
        sidebarBody
    }

    private var sidebarBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(SettingsView.Pane.allCases) { p in
                SidebarRow(pane: p, selected: p == pane)
                    .contentShape(Rectangle())
                    .onTapGesture { pane = p }
            }
            Spacer(minLength: 0)
            HelpRow()
        }
        .padding(.horizontal, 8)
        .padding(.top, 52)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.13), lineWidth: 1)
        )
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .frame(maxHeight: .infinity)
    }
}

private struct SidebarRow: View {
    let pane: SettingsView.Pane
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: pane.icon)
                .font(.system(size: 14, weight: selected ? .semibold : .regular))
                .frame(width: 22)
            Text(pane.title)
                .font(.system(size: 14, weight: selected ? .semibold : .regular))
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor : Color.clear)
        )
    }
}

private struct HelpRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 14, weight: .regular))
                .frame(width: 22)
            Text("帮助")
                .font(.system(size: 13, weight: .regular))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .opacity(0.8)
    }
}

private struct SettingsDetail: View {
    let pane: SettingsView.Pane
    @Bindable var model: SettingsModel
    var appState: AppState?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch pane {
                case .general: GeneralPane(model: model, appState: appState)
                case .ocr: OCRPane(model: model)
                case .about: AboutPane()
                }
            }
            .frame(maxWidth: 480, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.top, 32)
            .padding(.bottom, pane == .about ? 28 : 118)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .overlay(alignment: .bottom) {
            if pane != .about && (model.isDirty || model.statusMessage != nil) {
                ApplyBar(model: model)
                    .padding(.bottom, 28)
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

    init() {
        let paths = Paths.makeDefault()
        self.configPath = paths.configFile
        let cfg = (try? Config.load(from: paths.configFile)) ?? .default
        self.config = cfg
        self.initial = cfg
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
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
            VStack(spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
    }
}

private struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var isFirst = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst {
                Divider().padding(.leading, 16).opacity(0.55)
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .regular))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 10)
                trailing
            }
            .padding(.horizontal, 14)
            .padding(.vertical, subtitle == nil ? 8 : 10)
            .frame(minHeight: 40)
        }
    }
}

private struct SettingsNoteRow: View {
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            Divider().padding(.leading, 16).opacity(0.55)
            Text(text)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
    }
}

private struct SettingsBlock<Content: View>: View {
    var isFirst = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst {
                Divider().padding(.leading, 16).opacity(0.55)
            }
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
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
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup(title: "快捷键") {
                SettingsRow(title: "快捷键",
                            subtitle: "点按后直接输入新的组合键",
                            isFirst: true) {
                    HotkeyRecorder(config: $model.config.hotkey)
                        .frame(width: 138, height: 28)
                }
            }

            SettingsGroup(title: "存储模式") {
                SettingsRow(title: "blob 同步策略", isFirst: true) {
                    Picker("", selection: $model.config.mesh.storageMode) {
                        Text("完整 mirror").tag(StorageMode.full)
                        Text("按需拉取").tag(StorageMode.optimized)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)
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
        }
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
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup(title: "OCR 索引") {
                SettingsRow(title: "启用 OCR",
                            subtitle: "把图片里的文字写进搜索索引",
                            isFirst: true) {
                    Toggle("", isOn: $model.config.ocr.enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SettingsRow(title: "识别精度") {
                    Picker("", selection: $model.config.ocr.recognitionLevel) {
                        Text("accurate（默认）").tag("accurate")
                        Text("fast").tag("fast")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)
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
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.055))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        .frame(maxWidth: 190, alignment: .trailing)
                    }
                    .buttonStyle(.plain)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
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

            SettingsGroup(title: "Peers") {
                if peerList.isEmpty {
                    SettingsBlock(isFirst: true) {
                        Text("未配置 peer（standalone 模式）")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ForEach(Array(peerList.enumerated()), id: \.offset) { idx, entry in
                        SettingsBlock(isFirst: idx == 0) {
                            Text(entry)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
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
        .task { await subscribeStorageStats() }
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

    private var peerList: [String] {
        AppDelegate.shared?.dependencies?.config.peers.map { p -> String in
            let did = p.deviceID ?? "(learn)"
            if let pull = p.pullURL {
                return "\(p.url.absoluteString) · \(did)\n  pull → \(pull.absoluteString)"
            }
            return "\(p.url.absoluteString) · \(did)"
        } ?? []
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
            .buttonStyle(.plain)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(applyBarBackground)
        .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
    }

    private var needsRestartHint: Bool {
        model.statusMessage?.contains("重启") ?? false
    }

    @ViewBuilder
    private var applyBarBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }
}

private struct GlassActionButton: View {
    let title: String
    let isProminent: Bool
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isProminent ? Color.white : Color.primary)
                .frame(minWidth: 48)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(buttonBackground)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
    }

    @ViewBuilder
    private var buttonBackground: some View {
        let shape = Capsule(style: .continuous)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(
                .regular.tint(isProminent ? Color.accentColor.opacity(0.72) : Color.primary.opacity(0.08)),
                in: shape
            )
        } else {
            shape.fill(isProminent ? Color.accentColor : Color.primary.opacity(0.1))
        }
    }
}
