import AppKit
import Carbon.HIToolbox

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
    func register(
        keyCode: UInt32 = UInt32(kVK_ANSI_V),
        carbonModifiers: UInt32 = UInt32(cmdKey | optionKey),
        onFire: @escaping () -> Void
    ) throws {
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
