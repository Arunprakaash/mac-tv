import AppKit
import Security

/// Keeps Mac TV up to date from its GitHub releases. It checks at launch and once a day; installing
/// waits for the person to choose it in Settings › About, so an update never interrupts watching.
///
/// A downloaded update is installed only if it's signed by the same certificate as the running app
/// (its designated requirement), so nothing but a real Mac TV release can replace it.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle, checking, upToDate
        case available(version: String, download: URL)
        case downloading(Double)
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Called once per new version, for the notice on the home screen.
    var onAvailable: ((String) -> Void)?

    private static let latestRelease = URL(string: "https://api.github.com/repos/Arunprakaash/mac-tv/releases/latest")!
    private static let checkInterval: TimeInterval = 24 * 60 * 60
    private var timer: Timer?
    private var download: URLSessionDownloadTask?
    private var progress: NSKeyValueObservation?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var availableVersion: String? {
        if case .available(let version, _) = state { return version }
        return nil
    }

    func start() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            self.check()
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { _ in
            MainActor.assumeIsolated { Updater.shared.check() }
        }
    }

    /// The Software update row: installs an available update, otherwise checks now.
    func activate() {
        switch state {
        case .available(_, let url): install(from: url)
        case .checking, .downloading, .installing: break
        default: check()
        }
    }

    func check() {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        state = .checking
        var request = URLRequest(url: Self.latestRelease, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, error in
            let release = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            Task { @MainActor in
                let shared = Updater.shared
                guard let release, let tag = release["tag_name"] as? String else {
                    shared.state = .failed(error == nil ? "Couldn't read the latest release." : "Couldn't reach GitHub.")
                    return
                }
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let assets = release["assets"] as? [[String: Any]] ?? []
                guard Self.isNewer(version, than: Self.currentVersion) else { shared.state = .upToDate; return }
                guard let link = assets.lazy.compactMap({ $0["browser_download_url"] as? String })
                        .first(where: { $0.hasSuffix(".dmg") }),
                      let url = URL(string: link), url.scheme == "https" else {
                    shared.state = .upToDate
                    return
                }
                shared.state = .available(version: version, download: url)
                let noticed = UserDefaults.standard.string(forKey: "updateNoticeShown")
                if noticed != version {
                    UserDefaults.standard.set(version, forKey: "updateNoticeShown")
                    shared.onAvailable?(version)
                }
            }
        }.resume()
    }

    /// Dotted version comparison: 0.10 is newer than 0.9, and 0.12 than 0.11.1.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Installing

    private func install(from url: URL) {
        let bundle = Bundle.main.bundleURL
        guard !bundle.path.contains("/AppTranslocation/"), !bundle.path.hasPrefix("/Volumes/") else {
            state = .failed("Move Mac TV to Applications first.")
            return
        }
        guard FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path) else {
            state = .failed("Mac TV can't write to its folder. Download the update from GitHub.")
            return
        }
        state = .downloading(0)
        let task = URLSession.shared.downloadTask(with: url) { file, _, error in
            // The downloaded file is removed when this returns, so move it somewhere of our own first.
            var kept: URL?
            if let file {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacTV-update-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = folder.appendingPathComponent("update.dmg")
                if (try? FileManager.default.moveItem(at: file, to: target)) != nil { kept = target }
            }
            Task { @MainActor in
                Updater.shared.progress = nil
                guard let kept else {
                    Updater.shared.state = .failed(error == nil ? "The download didn't finish." : "Couldn't download the update.")
                    return
                }
                Updater.shared.state = .installing
                Updater.shared.installDiskImage(kept)
            }
        }
        progress = task.progress.observe(\.fractionCompleted) { progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                if case .downloading = Updater.shared.state { Updater.shared.state = .downloading(fraction) }
            }
        }
        download = task
        task.resume()
    }

    /// Mounts the disk image, checks the app inside, swaps it in and relaunches. The slow parts run off the main thread.
    private func installDiskImage(_ image: URL) {
        let bundle = Bundle.main.bundleURL
        let work = image.deletingLastPathComponent()
        let requirement = Self.ownRequirement()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.replaceApp(at: bundle, withAppIn: image, work: work, requirement: requirement)
            try? FileManager.default.removeItem(at: work)
            Task { @MainActor in
                switch result {
                case .success:
                    Self.relaunch(bundle)
                case .failure(let error):
                    Updater.shared.state = .failed(error.message)
                }
            }
        }
    }

    struct InstallError: Error { let message: String }

    private nonisolated static func replaceApp(at bundle: URL, withAppIn image: URL, work: URL,
                                               requirement: SecRequirement?) -> Result<Void, InstallError> {
        let mount = work.appendingPathComponent("mount")
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-readonly", "-quiet", "-mountpoint", mount.path]) else {
            return .failure(InstallError(message: "Couldn't open the update."))
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"]) }
        guard let found = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "app" }) else {
            return .failure(InstallError(message: "The update has no app in it."))
        }
        guard let requirement, isSigned(found, satisfying: requirement) else {
            return .failure(InstallError(message: "The update isn't signed like this copy of Mac TV. Download it from GitHub."))
        }
        // Copy next to the current app first, so the swap itself is a quick rename on the same disk.
        let staged = bundle.deletingLastPathComponent().appendingPathComponent(".Mac TV update.app")
        try? FileManager.default.removeItem(at: staged)
        guard run("/usr/bin/ditto", [found.path, staged.path]) else {
            return .failure(InstallError(message: "Couldn't copy the update."))
        }
        do {
            _ = try FileManager.default.replaceItemAt(bundle, withItemAt: staged)
            return .success(())
        } catch {
            try? FileManager.default.removeItem(at: staged)
            return .failure(InstallError(message: "Couldn't replace Mac TV. Download the update from GitHub."))
        }
    }

    /// The running app's designated requirement: its identifier and signing certificate.
    private static func ownRequirement() -> SecRequirement? {
        var code: SecCode?, staticCode: SecStaticCode?, requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    private nonisolated static func isSigned(_ app: URL, satisfying requirement: SecRequirement) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Opens the new copy once this one has quit.
    private static func relaunch(_ bundle: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.3; done; open \"$2\"",
                             "sh", String(ProcessInfo.processInfo.processIdentifier), bundle.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}
