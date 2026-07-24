import SwiftUI
import AppKit
import DuoPasteCore
import DuoPasteSync

/// 常规:快捷键、粘贴权限、存储模式、mesh 同步、传输路径、捕获守门、应用排除、iOS 配对。
struct GeneralPane: View {
    @Bindable var model: SettingsModel
    var appState: AppState?
    @State private var excludedBundleIDDraft = ""

    var body: some View {
        SettingsPage(pane: .general) {
            hotkeyCard
            if let appState {
                AccessibilityPermissionCard(appState: appState)
            }
            storageModeCard
            meshCard
            if let appState {
                TransportStatusCard(appState: appState)
            }
            captureLimitsCard
            exclusionCard
            IOSPairingCard(model: model)
        }
    }

    // MARK: - 快捷键

    private var hotkeyCard: some View {
        SettingsCard(header: "快捷键") {
            SettingsField(title: "快捷键", detail: "点按后直接输入新的组合键") {
                HotkeyRecorder(config: $model.config.hotkey)
                    .frame(width: 138, height: 28)
            }
        }
    }

    // MARK: - 存储模式

    private var storageModeCard: some View {
        SettingsCard(
            header: "存储模式",
            footer: model.config.mesh.storageMode == .full
                ? "PullWorker 每轮顺路把对端 blob 字节拉到本机做完整副本。日用机推荐。"
                : "只同步元数据；缩略图 / 预览 / 粘贴时按需 GET。给小盘备机 / iOS 用。"
        ) {
            SettingsField(title: "blob 同步策略") {
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
            }
        }
    }

    // MARK: - Mesh 同步

    private var meshCard: some View {
        SettingsCard(
            header: "Mesh 同步",
            footer: "WebSocket 会在对端 cursor_advanced 时推送，目标是 < 1s 同步延迟。"
        ) {
            SettingsToggleField(title: "启用 mesh 同步", isOn: $model.config.mesh.enabled)
            SettingsDivider()
            SettingsToggleField(title: "启用 WebSocket 实时通知", isOn: $model.config.mesh.wsEnabled)
            SettingsDivider()
            SettingsField(title: "Pull 周期") {
                Stepper(value: $model.config.mesh.pullIntervalSec, in: 5...600, step: 5) {
                    Text("\(model.config.mesh.pullIntervalSec) 秒").monospacedDigit()
                }
            }
        }
    }

    // MARK: - 捕获守门

    private var captureLimitsCard: some View {
        SettingsCard(
            header: "捕获守门",
            footer: "超过上限时 capture 跳过入库，剪贴板本身仍可 Cmd+V 粘贴。"
        ) {
            SettingsField(title: "blob 上限") {
                Stepper(value: blobMBBinding, in: 1...512) {
                    Text("\(blobMBBinding.wrappedValue) MB").monospacedDigit()
                }
            }
            SettingsDivider()
            SettingsField(title: "文本上限") {
                Stepper(value: textKBBinding, in: 1...8192, step: 16) {
                    Text("\(textKBBinding.wrappedValue) KB").monospacedDigit()
                }
            }
        }
    }

    // MARK: - 应用排除

    private var exclusionCard: some View {
        SettingsCard(
            header: "应用排除",
            footer: "列表保存后立即生效；排除只影响 duo-paste 历史，系统剪贴板与 Cmd+V 完全不受影响。"
        ) {
            SettingsField(
                title: "从运行中的应用添加",
                detail: "命中后不会读取正文、写数据库、存 blob、OCR 或同步"
            ) {
                Menu("选择应用…") {
                    if runningApplications.isEmpty {
                        Text("没有可选的运行中应用")
                    } else {
                        ForEach(runningApplications) { app in
                            Button {
                                model.addExcludedBundleID(app.bundleID)
                            } label: {
                                Text("\(app.name) — \(app.bundleID)")
                            }
                            .disabled(model.config.capture.excludedBundleIDs.contains(where: {
                                $0.caseInsensitiveCompare(app.bundleID) == .orderedSame
                            }))
                        }
                    }
                }
                .frame(width: 200)
            }

            SettingsDivider()

            SettingsField(title: "手动添加 bundle ID") {
                HStack(spacing: 8) {
                    TextField("com.example.App", text: $excludedBundleIDDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                        .onSubmit { addExcludedBundleIDDraft() }
                    GlassActionButton(
                        title: "添加",
                        isProminent: false,
                        isDisabled: excludedBundleIDDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ) {
                        addExcludedBundleIDDraft()
                    }
                }
            }

            ForEach(model.config.capture.excludedBundleIDs, id: \.self) { bundleID in
                SettingsDivider()
                HStack(spacing: 8) {
                    Text(bundleID)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 12)
                    Button {
                        model.removeExcludedBundleID(bundleID)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("从排除列表移除")
                }
                .settingsRow()
            }
        }
    }

    // MARK: - Binding / 数据

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

    private struct RunningApplication: Identifiable {
        let bundleID: String
        let name: String
        var id: String { bundleID.lowercased() }
    }

    private var runningApplications: [RunningApplication] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !bundleID.isEmpty
            else { return nil }
            let key = bundleID.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return RunningApplication(bundleID: bundleID, name: app.localizedName ?? bundleID)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func addExcludedBundleIDDraft() {
        if model.addExcludedBundleID(excludedBundleIDDraft) {
            excludedBundleIDDraft = ""
        }
    }
}

/// Accessibility 权限引导卡。daemon 启动时 AppDelegate 抓一次 AXIsProcessTrusted 写到
/// appState.accessibilityTrusted;这里渲染状态 + "打开系统设置" + "重新检查" 按钮。
/// AX 没 KVO,用户去系统设置勾完得回到这点 "重新检查",或者重启 daemon。
private struct AccessibilityPermissionCard: View {
    @Bindable var appState: AppState

    var body: some View {
        SettingsCard(
            header: "自动粘贴权限",
            footer: "授权后 panel 会用 .nonactivatingPanel 保留你原来的输入框焦点,双击条目自动模拟 Cmd+V 粘进去。未授权时不阻塞,只是要自己 Cmd+V。"
        ) {
            SettingsField(
                title: "Accessibility",
                detail: appState.accessibilityTrusted
                    ? "已授予 — 双击条目可直接粘到上一个输入框"
                    : "未授予 — pasteboard 仍会写好,需要切回原 app 自己 Cmd+V"
            ) {
                HStack(spacing: 8) {
                    if appState.accessibilityTrusted {
                        Image(systemName: "checkmark.circle.fill")
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
        }
    }

    /// 打开"系统设置 → 隐私与安全性 → 辅助功能"。URL scheme 在 macOS 13+ 稳定;
    /// 即便系统设置 UI 改版,这个 URL 都跳到正确面板。
    private func openAccessibilityPane() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
