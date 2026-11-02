import AppKit

/// An address the phone can open the remote at, with its QR code.
struct RemoteLink: Identifiable {
    let label: String
    let address: String
    /// The address to type when the phone can't open the Mac's name, like some older Android phones.
    var fallback: String? = nil
    let qr: NSImage?
    var id: String { address }
}
