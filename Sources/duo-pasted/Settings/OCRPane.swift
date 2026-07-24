import SwiftUI
import DuoPasteCore

/// OCR:索引开关 / 精度 / 单图上限、识别语言、本机索引队列状态。
struct OCRPane: View {
    @Bindable var model: SettingsModel
    @State private var isLanguagePickerPresented = false

    var body: some View {
        SettingsPage(pane: .ocr) {
            indexCard
            languageCard
            OCRIndexStatusCard(model: model)
        }
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

    // MARK: - OCR 索引

    private var indexCard: some View {
        SettingsCard(
            header: "OCR 索引",
            footer: "超过上限会标记 skipped，不喂 Vision。默认 16MB；fast 中文易漏字。"
        ) {
            SettingsToggleField(
                title: "启用 OCR",
                detail: "把图片里的文字写进搜索索引",
                isOn: $model.config.ocr.enabled)
            SettingsDivider()
            SettingsField(title: "识别精度") {
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
            }
            SettingsDivider()
            SettingsField(title: "单图字节上限") {
                Stepper(value: $model.config.ocr.maxBlobMB, in: 1...128) {
                    Text("\(model.config.ocr.maxBlobMB) MB").monospacedDigit()
                }
            }
        }
    }

    // MARK: - 识别语言

    private var languageCard: some View {
        SettingsCard(
            header: "识别语言",
            footer: "来自本机 Vision 支持列表；可连续勾选多个语言，仍会自动检测语言。"
        ) {
            SettingsField(title: "语言") {
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
        }
    }

    // MARK: - 语言数据

    private var selectedLanguageIDs: Set<String> {
        Set(model.config.ocr.languages)
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
/// - 已 done 行换语言/精度**不会**自动重做——配置只对增量生效。这个卡片让用户**看得见**
///   该事实(灰字"已完成 N 条使用原配置")并给"重建索引"按钮一键翻回 pending
/// - 中途用户改设置 + 重启,worker 用新 config 跑剩下队列 → 历史库半致状态;这里
///   显式接受,ApplyBar 在 ocr 字段 dirty + pending>0 时弹警告提示用户改完再 rebuild 对齐
/// - 中止用 pending → skipped(而非新增 cancelled 状态)——skipped 语义就是"本次不处理",
///   日后 `retry-failed-ocr` 一并恢复
private struct OCRIndexStatusCard: View {
    @Bindable var model: SettingsModel

    var body: some View {
        SettingsCard(header: "本机索引状态", footer: noteText) {
            SettingsField(title: "队列", detail: subtitleForQueue) {
                Text(queueDisplay)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            SettingsDivider()
            VStack(alignment: .leading, spacing: 0) {
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
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
            }
            .settingsRow()
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
