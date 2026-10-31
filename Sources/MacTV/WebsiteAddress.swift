import Foundation

/// Addresses typed on the phone open a website without adding a home-screen tile.
enum WebsiteAddress {
    static func url(from address: String) -> URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 4096,
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty,
              !host.contains(where: { $0.isWhitespace }), url.user == nil, url.password == nil else { return nil }
        return url
    }
}
