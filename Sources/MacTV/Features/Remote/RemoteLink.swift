import AppKit

/// An address the phone can open the remote at, with its QR code.
struct RemoteLink: Identifiable {
    let label: String
    let address: String
    let qr: NSImage?
    var id: String { address }
}
