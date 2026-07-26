import Foundation
import Testing
@testable import GilfoyleCore

@Suite("Local IPC", .serialized)
struct LocalIPCTests {
    @Test("Authenticated round trip and private socket permissions")
    func authenticatedRoundTripAndSocketPermissions() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("gf-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let socketURL = folder.appendingPathComponent("bridge.sock")
        let server = UnixSocketServer(socketURL: socketURL)
        defer { server.stop() }
        try server.start(token: "correct-token") { request, respond in
            respond(
                BridgeResponse(
                    requestID: request.requestID,
                    decision: .acknowledge
                )
            )
        }

        let request = BridgeRequest(
            token: "correct-token",
            agent: .codex,
            event: HookEventPayload(
                name: "SessionStart",
                sessionID: "session",
                cwd: "/tmp/project"
            ),
            terminal: TerminalContext(kind: .iTerm)
        )
        let response = try UnixSocketClient(socketURL: socketURL).send(request)
        #expect(response.decision == .acknowledge)
        #expect(response.requestID == request.requestID)

        let attributes = try FileManager.default.attributesOfItem(atPath: socketURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("Invalid token is rejected before the application handler")
    func invalidTokenIsDeniedBeforeHandler() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("gf-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let socketURL = folder.appendingPathComponent("bridge.sock")
        let server = UnixSocketServer(socketURL: socketURL)
        defer { server.stop() }
        var handlerCalled = false
        try server.start(token: "correct-token") { request, respond in
            handlerCalled = true
            respond(BridgeResponse(requestID: request.requestID, decision: .allow))
        }

        let request = BridgeRequest(
            token: "wrong-token",
            agent: .claude,
            event: HookEventPayload(
                name: "SessionStart",
                sessionID: "session",
                cwd: "/tmp/project"
            ),
            terminal: TerminalContext()
        )
        let response = try UnixSocketClient(socketURL: socketURL).send(request)
        #expect(response.decision == .deny)
        #expect(!handlerCalled)
    }

    @Test("Stopping an unstarted duplicate cannot remove the live bridge")
    func unstartedDuplicateCannotRemoveLiveBridge() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("gf-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let socketURL = folder.appendingPathComponent("bridge.sock")
        let live = UnixSocketServer(socketURL: socketURL)
        defer { live.stop() }
        try live.start(token: "token") { request, respond in
            respond(BridgeResponse(requestID: request.requestID, decision: .acknowledge))
        }

        let duplicate = UnixSocketServer(socketURL: socketURL)
        duplicate.stop()

        let response = try UnixSocketClient(socketURL: socketURL).send(
            request(token: "token")
        )
        #expect(response.decision == .acknowledge)
    }

    @Test("A duplicate server cannot steal an active bridge path")
    func duplicateServerCannotStealActiveBridge() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("gf-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let socketURL = folder.appendingPathComponent("bridge.sock")
        let live = UnixSocketServer(socketURL: socketURL)
        defer { live.stop() }
        try live.start(token: "token") { request, respond in
            respond(BridgeResponse(requestID: request.requestID, decision: .acknowledge))
        }

        let duplicate = UnixSocketServer(socketURL: socketURL)
        #expect(throws: LocalIPCError.self) {
            try duplicate.start(token: "other") { _, _ in }
        }
        duplicate.stop()

        let response = try UnixSocketClient(socketURL: socketURL).send(
            request(token: "token")
        )
        #expect(response.decision == .acknowledge)
    }

    private func request(token: String) -> BridgeRequest {
        BridgeRequest(
            token: token,
            agent: .claude,
            event: HookEventPayload(
                name: "SessionStart",
                sessionID: "session",
                cwd: "/tmp/project"
            ),
            terminal: TerminalContext()
        )
    }
}
