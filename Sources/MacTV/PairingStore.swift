import Foundation
import CryptoKit
import Security
import Darwin

/// Tokens are returned once to the phone; only their SHA-256 digests are stored on disk.
final class PairingStore {
    struct Device: Codable {
        let id: String
        let name: String
        let digest: String
        let createdAt: Date
        let expiresAt: Date?
        var isGuest: Bool { expiresAt != nil }
    }
    private let file: URL
    private let now: () -> Date
    private(set) var devices: [Device]
    private let readFailed: Bool

    init(folder: URL = AppFolder.url, now: @escaping () -> Date = Date.init) {
        file = folder.appendingPathComponent("paired-devices.json")
        self.now = now
        if FileManager.default.fileExists(atPath: file.path) {
            if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Device].self, from: data) {
                devices = saved; readFailed = false
            } else { devices = []; readFailed = true }
        } else { devices = []; readFailed = false }
    }
    private func save(_ updated: [Device]) throws {
        guard !readFailed else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(updated)
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".paired-devices-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard rename(temporary.path, file.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        devices = updated
    }
    func issue(name: String, guest: Bool) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        let date = now()
        let device = Device(id: UUID().uuidString, name: trimmed.isEmpty ? (guest ? "Guest" : "Phone") : trimmed,
                            digest: digest(token), createdAt: date, expiresAt: guest ? date.addingTimeInterval(24 * 60 * 60) : nil)
        try save(devices.filter { $0.expiresAt.map { $0 > date } ?? true } + [device])
        return token
    }
    func authenticate(_ token: String?) -> Device? {
        guard let token, token.count == 64 else { return nil }
        let hash = digest(token)
        return devices.first { $0.digest == hash && ($0.expiresAt.map { $0 > now() } ?? true) }
    }
    func activeDevices() -> [Device] { devices.filter { $0.expiresAt.map { $0 > now() } ?? true } }
    func revoke(id: String) throws { try save(devices.filter { $0.id != id }) }
    func revokeAll() throws { try save([]) }
    private func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
