import SwiftUI
import DuoPasteCore

/// SmartTransport 实时状态——AppState.transports 由 MeshSupervisor 启动 + reconcile
/// 完后 push 进来。@Bindable 让 AppState.transports / transportsUpdatedAt 变化自动
/// 重新渲染本组件（@Observable 跟踪机制）
struct TransportStatusCard: View {
    @Bindable var appState: AppState

    var body: some View {
        SettingsCard(header: "当前传输路径") {
            if appState.transports.isEmpty {
                SettingsField(title: "状态") {
                    Text("未连接 / 未配置 peer")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(Array(appState.transports.enumerated()), id: \.element.id) { idx, snapshot in
                    TransportPeerBlock(snapshot: snapshot, isFirst: idx == 0)
                }
            }
        } footer: {
            if appState.transports.isEmpty {
                Text("config.peers 为空 / mesh.enabled=false / shared-secret 加载失败时这里空。配置好 peer 重启 daemon 看效果。")
                    .fixedSize(horizontal: false, vertical: true)
            } else if let ts = appState.transportsUpdatedAt {
                Text(refreshNote(updatedAt: ts))
                    .fixedSize(horizontal: false, vertical: true)
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
struct TransportPeerBlock: View {
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

struct TransportCandidate: Identifiable, Sendable {
    let host: String
    let ms: Int64
    let kind: AppState.TransportSnapshot.Kind
    var id: String { host }
}

/// 单条 candidate 行——左：✓ + badge + host，右：RTT。chosen 主色，其他 secondary
struct CandidateRow: View {
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
