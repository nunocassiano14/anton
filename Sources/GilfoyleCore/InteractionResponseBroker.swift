import Foundation

public final class InteractionResponseBroker {
    public typealias Handler = (BridgeResponse) -> Void

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]

    public init() {}

    public var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return handlers.count
    }

    public func register(requestID: String, handler: @escaping Handler) {
        lock.lock()
        handlers[requestID] = handler
        lock.unlock()
    }

    @discardableResult
    public func resolve(requestID: String, response: BridgeResponse) -> Bool {
        lock.lock()
        let handler = handlers.removeValue(forKey: requestID)
        lock.unlock()
        guard let handler else { return false }
        handler(response)
        return true
    }

    @discardableResult
    public func cancelAll(message: String) -> Int {
        lock.lock()
        let pending = handlers
        handlers.removeAll()
        lock.unlock()

        for (requestID, handler) in pending {
            handler(
                BridgeResponse(
                    requestID: requestID,
                    decision: .cancel,
                    message: message
                )
            )
        }
        return pending.count
    }
}
