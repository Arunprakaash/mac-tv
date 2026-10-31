import Foundation
import Testing
@testable import MacTV

@Suite @MainActor struct BraveSessionTests {
    @Test func streamingAddresses() throws {
        #expect(try BraveSession.streamingURL(URL(string: "https://www.youtube.com/tv#/browse")!).absoluteString == "https://www.youtube.com/")
        let unusual = URL(string: "https://example.com/watch?q=%22%5C%27%26x%3D1")!
        #expect(try BraveSession.streamingURL(unusual) == unusual)
        #expect(throws: BraveSession.SessionError.self) { try BraveSession.streamingURL(URL(string: "file:///tmp/video")!) }
        #expect(throws: BraveSession.SessionError.self) { try BraveSession.streamingURL(URL(string: "javascript:alert(1)")!) }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/Applications/Brave Browser.app")))
    func appleScriptCompilesWithoutRunningBrave() throws {
        _ = try BraveSession.compileScript()
    }

    @Test func closedSessionCannotStartANewLaunch() async throws {
        let session = BraveSession()
        try session.close()
        await #expect(throws: CancellationError.self) {
            try await session.open(URL(string: "https://example.com")!)
        }
    }

    @Test func remoteKeys() {
        #expect(BraveSession.keyStroke(for: .move(.down)) == .init(code: 48))
        #expect(BraveSession.keyStroke(for: .move(.up)) == .init(code: 48, flags: .maskShift))
        #expect(BraveSession.keyStroke(for: .nextControl) == .init(code: 48))
        #expect(BraveSession.keyStroke(for: .previousControl) == .init(code: 48, flags: .maskShift))
        #expect(BraveSession.keyStroke(for: .seek(forward: true)) == .init(code: 124))
        #expect(BraveSession.keyStroke(for: .select) == .init(code: 36))
        #expect(BraveSession.keyStroke(for: .text("'\\\"\n")) == nil)
    }
}
