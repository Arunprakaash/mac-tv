import Foundation
import Testing
@testable import MacTV

struct WebsiteAddressTests {
    @Test func acceptsTypedAddressesAndPreservesQueries() {
        #expect(WebsiteAddress.url(from: "  youtube.com  ")?.absoluteString == "https://youtube.com")
        #expect(WebsiteAddress.url(from: "https://example.com/watch?q=a%26b#player")?.absoluteString == "https://example.com/watch?q=a%26b#player")
        #expect(WebsiteAddress.url(from: "http://127.0.0.1:18765/test")?.port == 18765)
    }

    @Test func rejectsNonWebAddressesCredentialsAndOversizedInput() {
        for address in ["", "   ", "file:///etc/passwd", "javascript:alert(1)", "data:text/html,hello", "https://user:password@example.com", "https://", "https://example.com\n/next", String(repeating: "a", count: 4097)] {
            #expect(WebsiteAddress.url(from: address) == nil, "Rejected: \(address.prefix(80))")
        }
    }
}
