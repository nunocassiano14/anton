import Foundation

public struct ShortcutConfiguration: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var command: Bool
    public var option: Bool
    public var control: Bool
    public var shift: Bool

    public init(
        keyCode: UInt32,
        command: Bool,
        option: Bool,
        control: Bool,
        shift: Bool
    ) {
        self.keyCode = keyCode
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
    }

    public static let defaultShortcut = ShortcutConfiguration(
        keyCode: 5,
        command: true,
        option: true,
        control: false,
        shift: false
    )

    public var displayName: String {
        var result = ""
        if control { result += "⌃" }
        if option { result += "⌥" }
        if shift { result += "⇧" }
        if command { result += "⌘" }
        result += keyName
        return result
    }

    private var keyName: String {
        let names: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z",
            7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
            14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
            20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
            26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
            32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J",
            39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 49: "Space"
        ]
        return names[keyCode] ?? "Key \(keyCode)"
    }
}

public struct StoredPreferences: Codable, Equatable, Sendable {
    public var shortcut: ShortcutConfiguration
    public var onboardingComplete: Bool
    public var lastLaunchAgent: AgentKind?
    public var lastLaunchWorkspace: String?
    public var lastLaunchTerminal: TerminalKind?

    public init(
        shortcut: ShortcutConfiguration = .defaultShortcut,
        onboardingComplete: Bool = false,
        lastLaunchAgent: AgentKind? = nil,
        lastLaunchWorkspace: String? = nil,
        lastLaunchTerminal: TerminalKind? = nil
    ) {
        self.shortcut = shortcut
        self.onboardingComplete = onboardingComplete
        self.lastLaunchAgent = lastLaunchAgent
        self.lastLaunchWorkspace = lastLaunchWorkspace
        self.lastLaunchTerminal = lastLaunchTerminal
    }
}

public final class PreferencesRepository {
    public static let defaultKey = "anton.preferences.v1"
    public static let legacyKey = "gilfoyle.preferences.v1"

    private let defaults: UserDefaults
    private let legacyDefaults: UserDefaults?
    private let key: String
    private let lock = NSLock()

    public init(
        defaults: UserDefaults = .standard,
        key: String = PreferencesRepository.defaultKey,
        legacyDefaults: UserDefaults? = UserDefaults(suiteName: "com.augustalabs.gilfoyle")
    ) {
        self.defaults = defaults
        self.key = key
        self.legacyDefaults = legacyDefaults
    }

    public func load() -> StoredPreferences {
        lock.lock()
        defer { lock.unlock() }
        if let decoded = decode(key) {
            return decoded
        }
        // The public app was renamed after an early local build. Keep daily-use
        // settings when Anton first starts, without retaining a second state store.
        if key == Self.defaultKey, let legacy = decode(Self.legacyKey) {
            return legacy
        }
        if key == Self.defaultKey,
           let legacy = decode(Self.legacyKey, from: legacyDefaults) {
            return legacy
        }
        return StoredPreferences()
    }

    public func save(_ preferences: StoredPreferences) throws {
        let data = try JSONEncoder().encode(preferences)
        lock.lock()
        defaults.set(data, forKey: key)
        lock.unlock()
    }

    private func decode(
        _ key: String,
        from source: UserDefaults? = nil
    ) -> StoredPreferences? {
        guard
            let data = (source ?? defaults).data(forKey: key),
            let decoded = try? JSONDecoder().decode(StoredPreferences.self, from: data)
        else {
            return nil
        }
        return decoded
    }
}
