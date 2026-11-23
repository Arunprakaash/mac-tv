import Foundation
import Network
import Testing
@testable import MacTV

/// A phone's saved remote only works at the port it was saved with, so the remote comes back on it.
@Suite @MainActor struct RemotePortTests {
    private func server() -> RemoteServer {
        RemoteServer(token: "", onCommand: { _ in }, state: { [:] }, icon: { _ in nil }, routes: { _ in nil })
    }

    private func listen(_ server: RemoteServer, on ports: [UInt16], waitForFirst: TimeInterval = 0) async throws -> UInt16 {
        var chosen: UInt16?
        server.start(ports: ports, waitForFirst: waitForFirst) { chosen = $0 }
        for _ in 0..<300 where chosen == nil { try await Task.sleep(for: .milliseconds(20)) }
        return try #require(chosen)
    }

    @Test func theRememberedPortComesFirst() {
        #expect(RemoteServer.ports(remembering: 0) == Array(8765...8775))
        #expect(RemoteServer.ports(remembering: 8768) == [8768, 8765, 8766, 8767] + Array(8769...8775))
        // Anything outside the range, as from an older or damaged setting, is ignored.
        #expect(RemoteServer.ports(remembering: 80) == Array(8765...8775))
        #expect(RemoteServer.ports(remembering: 70_000) == Array(8765...8775))
    }

    @Test func waitsForThePortTheLastMacTVIsLetGoOf() async throws {
        let first = UInt16.random(in: 20000...40000)
        let ports = [first, first + 1]
        let old = server()
        defer { old.stop() }
        #expect(try await listen(old, on: [first]) == first)

        // The Mac TV that's quitting lets go of the port a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated { old.stop() } }
        let new = server()
        defer { new.stop() }
        #expect(try await listen(new, on: ports, waitForFirst: 4) == first)
    }

    @Test func movesOnWhenThePortStaysBusy() async throws {
        let first = UInt16.random(in: 20000...40000)
        let holder = server()
        defer { holder.stop() }
        #expect(try await listen(holder, on: [first]) == first)

        let waiting = server()
        defer { waiting.stop() }
        let started = Date()
        #expect(try await listen(waiting, on: [first, first + 1], waitForFirst: 1) == first + 1)
        #expect(Date().timeIntervalSince(started) >= 0.9)

        let impatient = server()
        defer { impatient.stop() }
        #expect(try await listen(impatient, on: [first, first + 2]) == first + 2)
    }

    @Test func thePortAPhoneReachedIsRemembered() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) }
        let tv = TVController(library: AppLibrary(folder: folder))
        let saved = tv.remoteCoordinator.phonePort
        let paired = UserDefaults.standard.object(forKey: "phonePaired")
        defer {
            tv.remoteCoordinator.phonePort = saved
            UserDefaults.standard.set(paired, forKey: "phonePaired")
        }

        tv.remoteCoordinator.phonePort = 8765
        tv.remotePort = 8766
        #expect(tv.remoteCoordinator.phonePort == 8765, "Listening on another port doesn't move it")
        let state = tv.remoteState()
        #expect(tv.remoteCoordinator.phonePort == 8766, "A phone reaching the remote there does")
        if let home = tv.remoteCoordinator.homeOrigin {
            #expect(state["home"] as? String == home)
            #expect(home.hasSuffix(".local:8766"))
        }
    }
}
