import XCTest
@testable import ClaudeWidget

final class MagicLinkParserTests: XCTestCase {

    // MARK: - decodeEmail

    func testDecodesEmailFromValidLink() {
        // base64("dev.be.1@gempages.help") = "ZGV2LmJlLjFAZ2VtcGFnZXMuaGVscA=="
        let url = URL(string: "https://claude.ai/magic-link#tokenhex:ZGV2LmJlLjFAZ2VtcGFnZXMuaGVscA==")!
        XCTAssertEqual(MagicLinkParser.decodeEmail(from: url), "dev.be.1@gempages.help")
    }

    func testReturnsNilWhenFragmentMissing() {
        let url = URL(string: "https://claude.ai/magic-link")!
        XCTAssertNil(MagicLinkParser.decodeEmail(from: url))
    }

    func testReturnsNilWhenColonMissing() {
        let url = URL(string: "https://claude.ai/magic-link#tokenonly")!
        XCTAssertNil(MagicLinkParser.decodeEmail(from: url))
    }

    func testReturnsNilWhenBase64Invalid() {
        let url = URL(string: "https://claude.ai/magic-link#hex:not_base64!!!")!
        XCTAssertNil(MagicLinkParser.decodeEmail(from: url))
    }

    func testReturnsNilWhenBase64DecodesToEmptyString() {
        // base64("") = "" — already empty fragment after colon.
        let url = URL(string: "https://claude.ai/magic-link#hex:")!
        XCTAssertNil(MagicLinkParser.decodeEmail(from: url))
    }

    // MARK: - isLikelyMagicLink

    func testRecognizesValidLink() {
        XCTAssertTrue(MagicLinkParser.isLikelyMagicLink(
            "https://claude.ai/magic-link#a:b"))
    }

    func testRejectsWrongHost() {
        XCTAssertFalse(MagicLinkParser.isLikelyMagicLink(
            "https://example.com/magic-link#a:b"))
    }

    func testRejectsWrongPath() {
        XCTAssertFalse(MagicLinkParser.isLikelyMagicLink(
            "https://claude.ai/login#a:b"))
    }

    func testRejectsFragmentWithoutColon() {
        XCTAssertFalse(MagicLinkParser.isLikelyMagicLink(
            "https://claude.ai/magic-link#singletoken"))
    }

    func testRejectsEmptyString() {
        XCTAssertFalse(MagicLinkParser.isLikelyMagicLink(""))
        XCTAssertFalse(MagicLinkParser.isLikelyMagicLink("   "))
    }

    func testStripsLeadingTrailingWhitespace() {
        XCTAssertTrue(MagicLinkParser.isLikelyMagicLink(
            "  https://claude.ai/magic-link#a:b\n"))
    }
}
