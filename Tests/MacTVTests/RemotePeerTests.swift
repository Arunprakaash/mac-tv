import Network
import Testing
@testable import MacTV

struct RemotePeerTests {
    @Test func acceptsLocalPrivateAndTailscalePeers() {
        for address in ["127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.254", "192.168.0.2", "169.254.1.2", "100.64.0.1", "100.127.255.254", "::1", "fd7a:115c:a1e0::1", "fe80::1", "::ffff:192.168.0.2"] {
            #expect(RemotePeer.isPrivate(.hostPort(host: NWEndpoint.Host(address), port: 8765)), "Private peer: \(address)")
        }
    }
    @Test func rejectsPublicAndUnresolvedPeers() {
        for address in ["8.8.8.8", "172.15.1.2", "172.32.1.2", "100.63.0.1", "100.128.0.1", "2001:4860:4860::8888", "::ffff:8.8.8.8", "example.com"] {
            #expect(!RemotePeer.isPrivate(.hostPort(host: NWEndpoint.Host(address), port: 8765)), "Public peer: \(address)")
        }
    }
}
