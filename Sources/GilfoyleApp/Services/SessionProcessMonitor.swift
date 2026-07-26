import Darwin
import Foundation

@MainActor
final class SessionProcessMonitor {
    private struct Observation {
        let processID: pid_t
        let source: DispatchSourceProcess
    }

    private var observations: [String: Observation] = [:]

    func watch(
        sessionID: String,
        processID: Int32?,
        onExit: @escaping () -> Void
    ) {
        guard let processID, processID > 1 else { return }
        if observations[sessionID]?.processID == processID {
            return
        }

        stopWatching(sessionID: sessionID)
        guard Darwin.kill(processID, 0) == 0 || errno == EPERM else {
            onExit()
            return
        }

        let source = DispatchSource.makeProcessSource(
            identifier: pid_t(processID),
            eventMask: .exit,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.stopWatching(sessionID: sessionID)
            onExit()
        }
        observations[sessionID] = Observation(
            processID: pid_t(processID),
            source: source
        )
        source.resume()
    }

    func stopWatching(sessionID: String) {
        observations.removeValue(forKey: sessionID)?.source.cancel()
    }

    func stopAll() {
        let current = observations.values
        observations.removeAll()
        current.forEach { $0.source.cancel() }
    }
}
