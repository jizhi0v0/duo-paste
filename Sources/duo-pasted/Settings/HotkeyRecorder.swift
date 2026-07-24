import SwiftUI
import AppKit
import DuoPasteCore

struct HotkeyRecorder: NSViewRepresentable {
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

final class HotkeyRecorderField: NSView {
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
