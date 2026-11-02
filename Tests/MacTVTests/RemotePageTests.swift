import Foundation
import Testing
@testable import MacTV

@Suite struct RemotePageTests {
    @Test func pageIsServedWholeWithItsStylesAndScriptInline() {
        let html = RemotePage.html
        #expect(html.hasPrefix("<!doctype html>"))
        #expect(!html.contains("remote is missing") && !html.contains("page is missing"))
        #expect(!html.contains(#"href="remote.css""#) && !html.contains(#"src="remote.js""#))
        #expect(html.contains("<style>\n:root {") || html.contains("<style>\n  :root {"))
        #expect(html.contains("const $ = s => document.querySelector(s);"))
        #expect(html.hasSuffix("</html>\n"))
    }
}
