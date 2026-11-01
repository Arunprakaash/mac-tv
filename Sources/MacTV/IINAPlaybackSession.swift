import AppKit
import Darwin
import ApplicationServices

/// A private mpv IPC endpoint for one IINA launch; never sends keys to another app.
@MainActor
final class IINAPlaybackSession {
    enum PlaybackError: LocalizedError {
        case unavailable, invalidFile, noDisplay, accessibility, socketDirectory, launch(String), control(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: return "IINA is not installed."
            case .invalidFile: return "The movie file is not available."
            case .noDisplay: return "The selected display is no longer available."
            case .accessibility: return "Allow Mac TV in Privacy & Security > Accessibility to place IINA on your TV."
            case .socketDirectory: return "Mac TV could not create its private IINA control socket."
            case .launch(let detail): return "IINA could not be launched: \(detail)"
            case .control(let detail): return "IINA did not accept the remote command: \(detail)"
            }
        }
    }

    /// Called on the main actor if an asynchronously queued command fails.
    var onError: (@MainActor (Error) -> Void)?
    var onReady: (@MainActor () -> Void)?
    private var process: Process?
    var isRunning: Bool { !closed && process?.isRunning == true }
    var application: NSRunningApplication? {
        guard isRunning, let process else { return nil }
        return NSRunningApplication(processIdentifier: process.processIdentifier)
    }
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }
    private let cancellation = Cancellation()
    private let directory: String
    private let socketPath: String
    private let queue = DispatchQueue(label: "MacTV.IINAPlaybackSession.ipc", qos: .userInitiated)
    private var closed = false
    private var pendingCommands = 0
    private var startupDeadline: Date?

    init() throws {
        // mkdtemp creates a fresh 0700 directory; the short path fits macOS sockaddr_un.
        var template = Array("/tmp/mactv-iina.XXXXXXXX".utf8CString)
        guard let result = mkdtemp(&template) else { throw PlaybackError.socketDirectory }
        directory = String(cString: result)
        socketPath = directory + "/ipc"
    }

    func launch(file: URL, subtitle: URL?, position: Double?, screen: NSScreen) throws {
        guard file.isFileURL, FileManager.default.isReadableFile(atPath: file.path) else { throw PlaybackError.invalidFile }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.colliderli.iina") else { throw PlaybackError.unavailable }
        let executable = app.appendingPathComponent("Contents/MacOS/IINA")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw PlaybackError.unavailable }
        guard let index = NSScreen.screens.firstIndex(where: { $0.displayID == screen.displayID }) else { throw PlaybackError.noDisplay }
        let process = Process()
        process.executableURL = executable
        var args = ["--no-stdin", "--separate-windows", "--mpv-input-ipc-server=\(socketPath)",
                    "--mpv-screen=\(index)", "--mpv-fs-screen=\(index)", "--mpv-fullscreen=no"]
        if let position, position.isFinite, position > 0 { args.append("--mpv-start=\(position)") }
        if let subtitle { args.append("--mpv-sub-file=\(subtitle.path)") }
        args.append(file.path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw PlaybackError.launch(error.localizedDescription) }
        self.process = process
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                self.closed = true
                self.cancellation.cancel()
                try? FileManager.default.removeItem(atPath: self.directory)
                self.onError?(PlaybackError.control("IINA closed before playback finished. Open the movie again."))
            }
        }
        startupDeadline = Date().addingTimeInterval(6)
        let screenID = screen.displayID
        Task { @MainActor [weak self] in await self?.placeWindow(on: screenID) }
    }

    func activate() throws {
        guard let process, process.isRunning,
              let app = NSRunningApplication(processIdentifier: process.processIdentifier) else { throw PlaybackError.unavailable }
        app.activate(options: [])
    }

    private func placeWindow(on screenID: CGDirectDisplayID) async {
        guard AXIsProcessTrusted() else {
            onError?(PlaybackError.accessibility)
            enqueue(["set_property", "fullscreen", true])
            return
        }
        guard let process else { return }
        let appElement = AXUIElementCreateApplication(process.processIdentifier)
        for _ in 0..<60 {
            guard !closed, process.isRunning else { return }
            guard let screen = NSScreen.screens.first(where: { $0.displayID == screenID }) else {
                onError?(PlaybackError.noDisplay); return
            }
            var windowsValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
               let windows = windowsValue as? [AXUIElement], windows.count == 1, let window = windows.first {
                var isFullscreen: CFTypeRef?
                let fullscreenKey = "AXFullScreen" as CFString
                if AXUIElementCopyAttributeValue(window, fullscreenKey, &isFullscreen) == .success,
                   (isFullscreen as? Bool) == true {
                    _ = AXUIElementSetAttributeValue(window, fullscreenKey, kCFBooleanFalse)
                    try? await Task.sleep(for: .milliseconds(200))
                    continue
                }
                let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.maxY
                let frame = screen.visibleFrame
                var origin = CGPoint(x: frame.minX, y: primaryHeight - frame.maxY)
                var size = CGSize(width: frame.width, height: frame.height)
                guard let originValue = AXValueCreate(.cgPoint, &origin), let sizeValue = AXValueCreate(.cgSize, &size) else { break }
                let positioned = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originValue) == .success
                let sized = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success
                if positioned && sized {
                    var actualValue: CFTypeRef?
                    if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &actualValue) == .success,
                       let actualValue, CFGetTypeID(actualValue) == AXValueGetTypeID() {
                        var actual = CGPoint.zero
                        if AXValueGetValue(actualValue as! AXValue, .cgPoint, &actual),
                           abs(actual.x - origin.x) < 8, abs(actual.y - origin.y) < 8 {
                            enqueue(["set_property", "fullscreen", true], verifyScreen: screenID)
                            return
                        }
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        if !closed {
            onError?(PlaybackError.control("Could not place the IINA window on the selected display."))
            enqueue(["set_property", "fullscreen", true])
        }
    }

    private func verifyFullscreen(on screenID: CGDirectDisplayID) async {
        guard let process else { return }
        let appElement = AXUIElementCreateApplication(process.processIdentifier)
        for _ in 0..<20 {
            guard !closed, process.isRunning else { return }
            guard let screen = NSScreen.screens.first(where: { $0.displayID == screenID }) else {
                onError?(PlaybackError.noDisplay); return
            }
            var windowValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowValue) == .success,
               let windows = windowValue as? [AXUIElement], windows.count == 1, let window = windows.first {
                var full: CFTypeRef?, position: CFTypeRef?, size: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &full) == .success,
                   (full as? Bool) == true,
                   AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
                   AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
                   let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
                    var origin = CGPoint.zero, dimensions = CGSize.zero
                    if AXValueGetValue(position as! AXValue, .cgPoint, &origin),
                       AXValueGetValue(size as! AXValue, .cgSize, &dimensions) {
                        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.maxY
                        let bounds = CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY,
                                            width: screen.frame.width, height: screen.frame.height)
                        let center = CGPoint(x: origin.x + dimensions.width / 2, y: origin.y + dimensions.height / 2)
                        if bounds.contains(center) { onReady?(); return }
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if !closed { onError?(PlaybackError.control("IINA fullscreen could not be verified on the selected display.")) }
    }

    func loadSubtitle(_ url: URL) throws {
        guard !closed, url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else { throw PlaybackError.invalidFile }
        guard pendingCommands < 16 else { throw PlaybackError.control("Too many remote commands are pending.") }
        enqueue(["sub-add", url.path, "select"])
    }

    /// Enqueues a player command without blocking the UI. Commands wait briefly for startup,
    /// are serialized in order, and report failures through onError.
    static func action(for command: RemoteCommand) -> [Any]? {
        let action: [Any]
        switch command {
        case .playPause, .select: action = ["cycle", "pause"]
        case .seek(let forward): action = ["seek", forward ? 10 : -10, "relative"]
        case .move(.left): action = ["seek", -10, "relative"]
        case .move(.right): action = ["seek", 10, "relative"]
        case .volume(let delta): action = ["add", "volume", delta]
        case .mute: action = ["cycle", "mute"]
        case .move(.up): action = ["add", "volume", 5]
        case .move(.down): action = ["add", "volume", -5]
        case .browserFullscreen: action = ["cycle", "fullscreen"]
        case .back: action = ["set_property", "fullscreen", false]
        default: return nil
        }
        return action
    }

    @discardableResult
    func handle(_ command: RemoteCommand) -> Bool {
        guard !closed, let action = Self.action(for: command) else { return false }
        guard pendingCommands < 16 else {
            onError?(PlaybackError.control("Too many remote commands are pending."))
            return true
        }
        enqueue(action)
        return true
    }

    /// Stops and terminates only the dedicated IINA process created by this session.
    func close(immediate: Bool = false) {
        guard !closed else { return }
        closed = true
        cancellation.cancel()
        guard let process else {
            try? FileManager.default.removeItem(atPath: directory)
            return
        }
        if immediate {
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(atPath: directory)
            return
        }
        enqueue(["stop"], cleanup: true)
    }

    private func enqueue(_ command: [Any], cleanup: Bool = false, verifyScreen: CGDirectDisplayID? = nil) {
        let path = socketPath, folder = directory, cancellation = self.cancellation
        let ownedProcess = cleanup ? process : nil
        let deadline = cleanup ? Date().addingTimeInterval(6) : (startupDeadline ?? Date().addingTimeInterval(6))
        pendingCommands += 1
        queue.async { [weak self] in
            defer {
                if cleanup {
                    if let ownedProcess, ownedProcess.isRunning { ownedProcess.terminate() }
                    try? FileManager.default.removeItem(atPath: folder)
                }
                Task { @MainActor [weak self] in self?.pendingCommands -= 1 }
            }
            if !cleanup && cancellation.isCancelled { return }
            do {
                try Self.send(command, path: path, cancellation: cleanup ? nil : cancellation, deadline: deadline)
                if let verifyScreen, !cancellation.isCancelled {
                    Task { @MainActor [weak self] in await self?.verifyFullscreen(on: verifyScreen) }
                }
            } catch {
                if !cleanup && !cancellation.isCancelled {
                    Task { @MainActor [weak self] in self?.onError?(error) }
                }
            }
        }
    }

    nonisolated static func sendForTesting(_ command: [Any], path: String) throws {
        try send(command, path: path, cancellation: nil, deadline: Date().addingTimeInterval(6))
    }

    private nonisolated static func send(_ command: [Any], path: String, cancellation: Cancellation?, deadline: Date) throws {
        let payload = try JSONSerialization.data(withJSONObject: ["command": command]) + Data([10])
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw PlaybackError.socketDirectory }
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            pathBytes.withUnsafeBytes { source in target.copyBytes(from: source) }
        }
        var fd: Int32 = -1
        repeat {
            if cancellation?.isCancelled == true { throw CancellationError() }
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw PlaybackError.control("Could not create a connection.") }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
                }
            }
            if connected { break }
            Darwin.close(fd); fd = -1
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline
        guard fd >= 0 else { throw PlaybackError.control("The private player connection did not become available.") }
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let wrote = payload.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
        guard wrote else { throw PlaybackError.control("The player connection closed.") }
        var response = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        let responseDeadline = Date().addingTimeInterval(2)
        while response.count < 65536, Date() < responseDeadline {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { throw PlaybackError.control("The player did not respond.") }
            response.append(contentsOf: buffer.prefix(count))
            while let end = response.firstIndex(of: 10) {
                let line = response.prefix(upTo: end)
                response.removeSubrange(...end)
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let status = object["error"] as? String else { continue }
                guard status == "success" else { throw PlaybackError.control(status) }
                return
            }
        }
        throw PlaybackError.control("The player sent an invalid response.")
    }
}
