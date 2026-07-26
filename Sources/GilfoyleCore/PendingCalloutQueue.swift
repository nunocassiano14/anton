public struct PendingCalloutQueue: Equatable, Sendable {
    private var urgentSessionIDs: [String] = []
    private var normalSessionIDs: [String] = []

    public init() {}

    public var count: Int { urgentSessionIDs.count + normalSessionIDs.count }

    public mutating func enqueue(sessionID: String, urgent: Bool) {
        if urgent {
            guard !urgentSessionIDs.contains(sessionID) else { return }
            normalSessionIDs.removeAll { $0 == sessionID }
            urgentSessionIDs.append(sessionID)
        } else if !urgentSessionIDs.contains(sessionID),
                  !normalSessionIDs.contains(sessionID) {
            normalSessionIDs.append(sessionID)
        }
    }

    public mutating func popFirst() -> String? {
        if !urgentSessionIDs.isEmpty {
            return urgentSessionIDs.removeFirst()
        }
        return normalSessionIDs.isEmpty ? nil : normalSessionIDs.removeFirst()
    }

    public mutating func remove(sessionID: String) {
        urgentSessionIDs.removeAll { $0 == sessionID }
        normalSessionIDs.removeAll { $0 == sessionID }
    }

    public mutating func removeAll() {
        urgentSessionIDs.removeAll()
        normalSessionIDs.removeAll()
    }
}
