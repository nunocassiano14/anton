import Carbon
import Foundation
import GilfoyleCore

final class GlobalShortcutManager {
    var action: (() -> Void)?

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    init() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventCallback,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    func register(_ shortcut: ShortcutConfiguration) throws {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        var modifiers: UInt32 = 0
        if shortcut.command { modifiers |= UInt32(cmdKey) }
        if shortcut.option { modifiers |= UInt32(optionKey) }
        if shortcut.control { modifiers |= UInt32(controlKey) }
        if shortcut.shift { modifiers |= UInt32(shiftKey) }

        let identifier = EventHotKeyID(signature: fourCharacterCode("GILF"), id: 1)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "The keyboard shortcut could not be registered."]
            )
        }
    }

    private static let eventCallback: EventHandlerUPP = { _, _, userData in
        guard let userData else { return noErr }
        let manager = Unmanaged<GlobalShortcutManager>
            .fromOpaque(userData)
            .takeUnretainedValue()
        DispatchQueue.main.async {
            manager.action?()
        }
        return noErr
    }
}

private func fourCharacterCode(_ value: String) -> OSType {
    value.utf8.prefix(4).reduce(0) { partial, byte in
        (partial << 8) | OSType(byte)
    }
}
