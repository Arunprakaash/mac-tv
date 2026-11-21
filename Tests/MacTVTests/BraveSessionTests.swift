import Foundation
import Testing
@testable import MacTV

@Suite @MainActor struct BraveSessionTests {
    @Test func streamingAddresses() throws {
        #expect(try BrowserSession.streamingURL(URL(string: "https://www.youtube.com/tv#/browse")!).absoluteString == "https://www.youtube.com/")
        let unusual = URL(string: "https://example.com/watch?q=%22%5C%27%26x%3D1")!
        #expect(try BrowserSession.streamingURL(unusual) == unusual)
        #expect(throws: BrowserSession.SessionError.self) { try BrowserSession.streamingURL(URL(string: "file:///tmp/video")!) }
        #expect(throws: BrowserSession.SessionError.self) { try BrowserSession.streamingURL(URL(string: "javascript:alert(1)")!) }
    }

    @Test func closedSessionCannotStartANewLaunch() async throws {
        let session = BrowserSession(bundleID: "com.brave.Browser", name: "Brave")
        try session.close()
        await #expect(throws: CancellationError.self) {
            try await session.open(URL(string: "https://example.com")!)
        }
    }

    @Test func theWindowGoingAwayReportsOnceButClosingItDoesNot() {
        let session = BrowserSession(bundleID: "com.brave.Browser", name: "Brave")
        var reports = 0
        session.onClose = { reports += 1 }
        session.windowWentAway()
        session.windowWentAway()
        #expect(reports == 1)

        let closed = BrowserSession(bundleID: "com.brave.Browser", name: "Brave")
        closed.onClose = { reports += 1 }
        try? closed.close()
        closed.windowWentAway()
        #expect(reports == 1)
    }

    @Test func permissionPaneFollowsTheMacOSVersion() {
        #expect(BrowserSession.paneName(for: .init(majorVersion: 26, minorVersion: 4, patchVersion: 0)) == "Accessibility")
        #expect(BrowserSession.paneName(for: .init(majorVersion: 27, minorVersion: 0, patchVersion: 1)) == "Device Control and Data Access")
    }

    @Test func remoteKeys() {
        #expect(BrowserSession.keyStroke(for: .move(.down)) == .init(code: 48))
        #expect(BrowserSession.keyStroke(for: .move(.up)) == .init(code: 48, flags: .maskShift))
        #expect(BrowserSession.keyStroke(for: .nextControl) == .init(code: 48))
        #expect(BrowserSession.keyStroke(for: .previousControl) == .init(code: 48, flags: .maskShift))
        #expect(BrowserSession.keyStroke(for: .seek(forward: true)) == .init(code: 124))
        #expect(BrowserSession.keyStroke(for: .select) == .init(code: 36))
        #expect(BrowserSession.keyStroke(for: .text("'\\\"\n")) == nil)
    }
}
