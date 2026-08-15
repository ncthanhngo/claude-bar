import XCTest
@testable import ClaudeSwapWidget

/// Covers the decode robustness `NewsFeed`/`NewsCard`/`RepoCard` promise in
/// plans/260815-1455-news-dashboard/contract.md: arrays are always emitted
/// as `[]` (never `null`), and unknown category strings degrade to `.other`
/// instead of failing the whole decode.
final class NewsDTOTests: XCTestCase {
    func testDecodesBundledMockFixture() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "news-mock", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let feed = try JSONDecoder().decode(NewsFeed.self, from: data)

        XCTAssertFalse(feed.items.isEmpty)
        XCTAssertFalse(feed.repos.isEmpty)
        XCTAssertEqual(feed.role, "master")
        XCTAssertTrue(feed.items.allSatisfy { !$0.id.isEmpty })
        XCTAssertTrue(feed.repos.allSatisfy { !$0.fullName.isEmpty })
    }

    func testMissingArraysDefaultToEmptyNotNil() throws {
        // A Go `nil` slice serializes to JSON `null` — this is the exact
        // shape a backend regression could emit; the decode must survive it.
        let json = """
        { "items": null, "repos": null }
        """.data(using: .utf8)!

        let feed = try JSONDecoder().decode(NewsFeed.self, from: json)

        XCTAssertEqual(feed.items, [])
        XCTAssertEqual(feed.repos, [])
        XCTAssertEqual(feed.sourcesHealth, [:])
    }

    func testUnknownCategoryFallsBackToOther() throws {
        let json = """
        {
          "id": "x", "category": "quantum-computing", "title": "t",
          "sourceLabel": "s", "sourceFaviconURL": "", "imageURL": "",
          "summaryVI": "", "fullVI": "", "originalURL": "", "publishedAt": ""
        }
        """.data(using: .utf8)!

        let card = try JSONDecoder().decode(NewsCard.self, from: json)

        XCTAssertEqual(card.category, .other)
    }

    func testEmptyPublishedAtParsesToNilRelativeLabel() {
        XCTAssertEqual(NewsDateFormatting.relativeLabel(""), "")
        XCTAssertNil(NewsDateFormatting.parse(""))
    }
}
