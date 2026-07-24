import SwiftUI
import AppKit
import DuoPasteCore
import DuoPasteSync

/// daemon 在 serve=true 时通过 BonjourAdvertiser 广播 `_duopaste._tcp`,iOS Settings
/// 端扫码取得 endpoint + leaf pin，再输 6 位 PIN → POST /pair/<pin> 拿 credential + endpoints。
/// 60s expiry + 5 次错误封锁,PIN 用过即失效
@MainActor
struct IOSPairingCard: View {
    @Bindable var model: SettingsModel
    @State private var showPIN: Bool = false

    var body: some View {
        SettingsCard(
            header: "iOS 配对",
            footer: model.pairingChannelBindingReady
                ? "iOS 必须扫描此 Mac 的 QR，再输入同屏 6 位 PIN。QR 绑定当前 TLS leaf；PIN 60s 失效，错 5 次封锁。"
                : "安全配对需要 serve=true、HTTPS 和可读取的 tls_cert_path；条件不满足时不会生成 QR/PIN。"
        ) {
            SettingsField(
                title: "广播状态",
                detail: model.config.serve
                    ? "本机 daemon serve=true → Bonjour 广播 _duopaste._tcp · iOS Settings 可见"
                    : "未开启 serve → iOS 看不到本机。先开 serve 再来配对"
            ) {
                Text(model.config.serve ? "ON" : "OFF")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.config.serve ? Color.green : Color.secondary)
            }
            SettingsDivider()
            SettingsField(title: "PIN 配对") {
                GlassActionButton(title: "显示配对码", isProminent: true,
                                  isDisabled: !model.pairingChannelBindingReady) {
                    showPIN = true
                }
                .controlSize(.small)
            }
        }
        .sheet(isPresented: $showPIN) {
            IOSPairingPINSheet(model: model, isPresented: $showPIN)
        }
    }
}

// MARK: - PIN 配对 sheet

@MainActor
struct IOSPairingPINSheet: View {
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
                // QR 带 endpoint + leaf pin；PIN 仍由用户从同屏手输。
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: 260, height: 260)
                    .background(Color.white)
                    .padding(8)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "lock.trianglebadge.exclamationmark")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
                    Text("无法生成安全配对码")
                        .font(.system(size: 13, weight: .semibold))
                    Text("检查 HTTPS 与 tls_cert_path 后重开此窗口")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 260, height: 260)
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
                Text("iOS 已拿到独立凭据 + endpoints，正在连接…")
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
            guard qrImage != nil else {
                errorText = "安全配对需要 HTTPS 与可读取的 leaf certificate"
                return
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
            qrImage = nil
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
        qrImage = model.pairingQRImage()
        guard qrImage != nil else {
            errorText = "TLS leaf 不可读取，已停止生成 PIN"
            return
        }
        Task { @MainActor in
            let (newPin, sec) = await service.generatePIN()
            self.pin = newPin
            self.secondsLeft = sec
            self.sessionStartedAt = Date()
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
