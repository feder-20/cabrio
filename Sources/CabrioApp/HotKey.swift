import AppKit
import SwiftUI
import Carbon.HIToolbox

/// Atajo global (Carbon `RegisterEventHotKey`): no pide permisos de accesibilidad.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    var onPress: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false

    @discardableResult
    func register(code: UInt32, mods: UInt32) -> Bool {
        unregister()
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in HotKeyCenter.shared.onPress?() }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        let id = EventHotKeyID(signature: OSType(0x43425249), id: 1)   // «CBRI»
        return RegisterEventHotKey(code, mods, id, GetApplicationEventTarget(), 0, &ref) == noErr
    }

    func unregister() {
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
    }

    /// Aplica el atajo guardado en preferencias. Falso si otro programa ya lo usa.
    @discardableResult
    func applyPreferences() -> Bool {
        guard let h = Prefs.hotKey else { unregister(); return true }
        return register(code: h.code, mods: h.mods)
    }
}

/// Campo que graba una combinación de teclas. Exige ⌘, ⌃ o ⌥ para no robar teclas normales.
struct HotKeyRecorder: NSViewRepresentable {
    @Binding var label: String
    var onRecord: (UInt32, UInt32) -> Void

    func makeNSView(context: Context) -> RecorderField {
        let v = RecorderField()
        v.onRecord = onRecord
        v.onLabel = { label = $0 }
        v.refresh(label)
        return v
    }

    func updateNSView(_ v: RecorderField, context: Context) {
        v.onRecord = onRecord
        v.refresh(label)
    }

    final class RecorderField: NSButton {
        var onRecord: (UInt32, UInt32) -> Void = { _, _ in }
        var onLabel: (String) -> Void = { _ in }
        private var recording = false { didSet { title = recording ? L("Pulsa el atajo…") : shown } }
        private var shown = ""

        override init(frame: NSRect) {
            super.init(frame: frame)
            bezelStyle = .rounded
            setButtonType(.momentaryPushIn)
            target = self
            action = #selector(toggle)
        }
        required init?(coder: NSCoder) { fatalError() }

        func refresh(_ label: String) { shown = label; if !recording { title = label } }
        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }

        @objc private func toggle() {
            recording.toggle()
            if recording { window?.makeFirstResponder(self) }
        }

        override func resignFirstResponder() -> Bool { recording = false; return super.resignFirstResponder() }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording else { return false }
            keyDown(with: event)
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard recording else { return super.keyDown(with: event) }
            if event.keyCode == UInt16(kVK_Escape) { recording = false; return }
            let mods = Prefs.carbonModifiers(from: event.modifierFlags)
            guard mods & UInt32(cmdKey | controlKey | optionKey) != 0 else { NSSound.beep(); return }
            recording = false
            onRecord(UInt32(event.keyCode), mods)
        }
    }
}
