import Network

/// The phone service is for local links and private networks, not public Internet clients.
enum RemotePeer {
    static func isPrivate(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return privateIPv4(Array(address.rawValue))
        case .ipv6(let address):
            let bytes = Array(address.rawValue)
            guard bytes.count == 16 else { return false }
            if bytes.prefix(15).allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }
            if bytes[0] & 0xfe == 0xfc { return true } // Unique-local, including Tailscale IPv6.
            if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return true } // Link-local.
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                return privateIPv4(Array(bytes.suffix(4)))
            }
            return false
        default: return false
        }
    }

    private static func privateIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        return bytes[0] == 127 || bytes[0] == 10
            || (bytes[0] == 172 && (16...31).contains(bytes[1]))
            || (bytes[0] == 192 && bytes[1] == 168)
            || (bytes[0] == 169 && bytes[1] == 254)
            || (bytes[0] == 100 && (64...127).contains(bytes[1])) // Tailscale / shared-address space.
    }
}
