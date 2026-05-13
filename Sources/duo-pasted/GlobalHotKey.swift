import AppKit
import Carbon.HIToolbox
import DuoPasteCore

/// 把 `HotkeyConfig`（字符串风格）翻译成 Carbon RegisterEventHotKey 接受的 keyCode +
/// modifier bitmask。Config 层负责合法性校验（validate()），这里只做映射，所以查表
/// 永远命中——失败抛出意味着 Config.validate 漏过了什么，是程序员错误
///
/// 不把这逻辑放在 DuoPasteCore：Config 模块不依赖 Carbon，跨设备配置同步将来如果做
/// iOS 客户端也能复用。daemon 进程才需要 Carbon 桥接
enum HotkeyTranslation {
    /// `HotkeyConfig.key`（A-Z / 0-9）→ kVK_ANSI_* 常量。
    /// 表必须跟 `HotkeyConfig.supportedKeys` 覆盖一致，否则会出现 "config 校验通过但
    /// 翻译失败" 的诡异 case
    static let keyToCode: [String: Int] = [
        "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D,
        "E": kVK_ANSI_E, "F": kVK_ANSI_F, "G": kVK_ANSI_G, "H": kVK_ANSI_H,
        "I": kVK_ANSI_I, "J": kVK_ANSI_J, "K": kVK_ANSI_K, "L": kVK_ANSI_L,
        "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O, "P": kVK_ANSI_P,
        "Q": kVK_ANSI_Q, "R": kVK_ANSI_R, "S": kVK_ANSI_S, "T": kVK_ANSI_T,
        "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X,
        "Y": kVK_ANSI_Y, "Z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
        "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    ]

    struct TranslationError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    static func translate(_ cfg: Config.HotkeyConfig) throws -> (keyCode: UInt32, modifiers: UInt32) {
        let normalized = cfg.key.uppercased()
        guard let kc = keyToCode[normalized] else {
            throw TranslationError(message: "hotkey.key 不支持：\(cfg.key)")
        }
        var mask: UInt32 = 0
        for m in cfg.modifiers {
            switch m.lowercased() {
            case "cmd", "command":  mask |= UInt32(cmdKey)
            case "option", "alt":   mask |= UInt32(optionKey)
            case "control", "ctrl": mask |= UInt32(controlKey)
            case "shift":           mask |= UInt32(shiftKey)
            default:
                throw TranslationError(message: "hotkey.modifiers 不支持：\(m)")
            }
        }
        return (UInt32(kc), mask)
    }
}

/// 通过 Carbon RegisterEventHotKey 注册一个进程级全局快捷键。
/// 单实例。回调在主线程。
@MainActor
final class GlobalHotKey {
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var handlerRef: EventHandlerRef?
    private let signature: OSType
    private let id: UInt32
    private var handler: (() -> Void)?

    init(signature: String = "DPst", id: UInt32 = 1) {
        // 4-char OSType
        self.signature = Self.osType(from: signature)
        self.id = id
    }

    deinit {
        // Carbon 句柄是不透明指针，nonisolated deinit 释放即可
        if let h = handlerRef { RemoveEventHandler(h) }
        if let r = hotKeyRef { UnregisterEventHotKey(r) }
    }

    /// 注册 ⌥⌘V（默认）。失败抛错，便于调用方降级。
    /// 幂等：重复调用先 unregister 旧 hotkey + remove 旧 handler，再注册新组合——
    /// 让"自定义失败回退默认"或将来 config reload 都能干净接管，不泄漏 Carbon 句柄
    func register(
        keyCode: UInt32 = UInt32(kVK_ANSI_V),
        carbonModifiers: UInt32 = UInt32(cmdKey | optionKey),
        onFire: @escaping () -> Void
    ) throws {
        if let h = handlerRef {
            RemoveEventHandler(h)
            handlerRef = nil
        }
        if let r = hotKeyRef {
            UnregisterEventHotKey(r)
            hotKeyRef = nil
        }
        self.handler = onFire
        Self.shared = self

        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var hkRef: EventHotKeyRef?
        let regStatus = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hkRef
        )
        guard regStatus == noErr, let hk = hkRef else {
            throw HotKeyError.registrationFailed(Int(regStatus))
        }
        self.hotKeyRef = hk

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handler: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.handlerC,
            1,
            &eventType,
            nil,
            &handler
        )
        guard installStatus == noErr, let hRef = handler else {
            UnregisterEventHotKey(hk)
            self.hotKeyRef = nil
            throw HotKeyError.handlerInstallFailed(Int(installStatus))
        }
        self.handlerRef = hRef
    }

    enum HotKeyError: Error, CustomStringConvertible {
        case registrationFailed(Int)
        case handlerInstallFailed(Int)
        var description: String {
            switch self {
            case .registrationFailed(let s): "RegisterEventHotKey failed: \(s)"
            case .handlerInstallFailed(let s): "InstallEventHandler failed: \(s)"
            }
        }
    }

    // MARK: - Carbon glue

    /// 单实例引用，因为 Carbon C 回调没法捕获 self。
    nonisolated(unsafe) private static var shared: GlobalHotKey?

    private static let handlerC: EventHandlerUPP = { _, eventRef, _ in
        guard let event = eventRef else { return noErr }
        var hkID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hkID
        )
        guard status == noErr else { return status }
        Task { @MainActor in
            shared?.handler?()
        }
        return noErr
    }

    private static func osType(from s: String) -> OSType {
        let bytes = Array(s.utf8.prefix(4))
        var v: UInt32 = 0
        for b in bytes {
            v = (v << 8) | UInt32(b)
        }
        return OSType(v)
    }
}
