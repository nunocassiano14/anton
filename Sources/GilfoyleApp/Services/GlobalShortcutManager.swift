import Carbon
import Foundation
import GilfoyleCore

enum GlobalShortcutAction: UInt32 {
    case toggle = 1
    case newSession = 2
    case resumeSession = 3
    case resumeLatest = 4
}

final class GlobalShortcutManager {
    var action: ((GlobalShortcutAction) -> Void)?

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [GlobalShortcutAction: EventHotKeyRef] = [:]

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
        hotKeyRefs.values.forEach { hotKeyRef in
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    func register(
        _ shortcut: ShortcutConfiguration,
        for action: GlobalShortcutAction = .toggle
    ) throws {
        if let existing = hotKeyRefs.removeValue(forKey: action) {
            UnregisterEventHotKey(existing)
        }

        var modifiers: UInt32 = 0
        if shortcut.command { modifiers |= UInt32(cmdKey) }
        if shortcut.option { modifiers |= UInt32(optionKey) }
        if shortcut.control { modifiers |= UInt32(controlKey) }
        if shortcut.shift { modifiers |= UInt32(shiftKey) }

        let identifier = EventHotKeyID(
            signature: fourCharacterCode("ANTO"),
            id: action.rawValue
        )
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The keyboard shortcut could not be registered."
                ]
            )
        }
        hotKeyRefs[action] = reference
    }

    private static let eventCallback: EventHandlerUPP = { _, event, userData in
        guard let userData, let event else { return noErr }
        var identifier = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )
        guard
            status == noErr,
            let action = GlobalShortcutAction(rawValue: identifier.id)
        else {
            return noErr
        }
        let manager = Unmanaged<GlobalShortcutManager>
            .fromOpaque(userData)
            .takeUnretainedValue()
        DispatchQueue.main.async {
            manager.action?(action)
        }
        return noErr
    }
}

private func fourCharacterCode(_ value: String) -> OSType {
    value.utf8.prefix(4).reduce(0) { partial, byte in
        (partial << 8) | OSType(byte)
    }
}
