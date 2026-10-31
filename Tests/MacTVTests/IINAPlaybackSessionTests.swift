import Darwin
import Foundation
import Testing
@testable import MacTV

private final class IPCMock: @unchecked Sendable {
    let directory: String
    let path: String
    private let listener: Int32
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var received = Data()

    init(reply: String) throws {
        var template = Array("/tmp/mactv-test.XXXXXXXX".utf8CString)
        guard let name = mkdtemp(&template) else { throw MockError.setup }
        directory = String(cString: name)
        path = directory + "/ipc"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MockError.setup }
        listener = fd
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else { Darwin.close(fd); throw MockError.setup }
        DispatchQueue.global().async { [self] in
            defer { finished.signal() }
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            defer { Darwin.close(connection) }
            var buffer = [UInt8](repeating: 0, count: 1024)
            let count = Darwin.read(connection, &buffer, buffer.count)
            if count > 0 {
                lock.lock(); received = Data(buffer.prefix(count)); lock.unlock()
            }
            _ = reply.withCString { Darwin.write(connection, $0, strlen($0)) }
        }
    }

    func message() throws -> [String: Any] {
        guard finished.wait(timeout: .now() + 3) == .success else { throw MockError.timeout }
        lock.lock(); let data = received; lock.unlock()
        guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MockError.setup }
        return message
    }

    deinit { Darwin.close(listener); try? FileManager.default.removeItem(atPath: directory) }
    enum MockError: Error { case setup, timeout }
}

@Suite @MainActor struct IINAPlaybackSessionTests {
    @Test func seekIsSentAsJSONAndAcknowledged() throws {
        let server = try IPCMock(reply: "{\"event\":\"start-file\"}\n{\"error\":\"success\"}\n")
        let command = try #require(IINAPlaybackSession.action(for: .seek(forward: true)))
        try IINAPlaybackSession.sendForTesting(command, path: server.path)
        let sent = try server.message()
        let values = try #require(sent["command"] as? [Any])
        #expect(values.count == 3)
        #expect(values[0] as? String == "seek")
        #expect(values[1] as? Int == 10)
        #expect(values[2] as? String == "relative")
    }

    @Test func fullscreenErrorIsReported() throws {
        let server = try IPCMock(reply: "{\"error\":\"property unavailable\"}\n")
        let command = try #require(IINAPlaybackSession.action(for: .browserFullscreen))
        #expect(throws: IINAPlaybackSession.PlaybackError.self) {
            try IINAPlaybackSession.sendForTesting(command, path: server.path)
        }
        let sent = try server.message()
        #expect(sent["command"] as? [String] == ["cycle", "fullscreen"])
    }
}
