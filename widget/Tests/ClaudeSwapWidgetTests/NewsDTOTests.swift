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

    func testNewsCardRoundTripsThroughEncodeDecode() throws {
        // NewsCard/RepoCard gained Encodable in Iteration 2 so NewsStore can
        // re-encode a card as the `csw news save` stdin payload — this
        // guards that the CodingKeys stay symmetric (encode then decode
        // yields the same value) rather than silently drifting from
        // contract.md's field names.
        let card = NewsCard(
            id: "abc", category: .ai, title: "T", titleVI: "TVI",
            sourceLabel: "S", sourceFaviconURL: "https://x/f.png", imageURL: "https://x/i.jpg",
            summaryVI: "sum", fullVI: "full", originalURL: "https://x", publishedAt: "2026-08-15T06:00:00Z"
        )
        let data = try JSONEncoder().encode(card)
        let decoded = try JSONDecoder().decode(NewsCard.self, from: data)
        XCTAssertEqual(decoded, card)
    }

    func testRepoCardRoundTripsThroughEncodeDecode() throws {
        let repo = RepoCard(
            id: "ollama/ollama", fullName: "ollama/ollama", descVI: "d", language: "Go",
            langColor: "#00add8", stars: 100, deltaWeek: 5, url: "https://x", category: .github
        )
        let data = try JSONEncoder().encode(repo)
        let decoded = try JSONDecoder().decode(RepoCard.self, from: data)
        XCTAssertEqual(decoded, repo)
    }

    func testArticleDTODecodesSuccessAndFailureShapes() throws {
        let ok = """
        { "url":"https://x","titleVI":"T","contentVI":"Đoạn 1.\\n\\nĐoạn 2.",
          "provider":"ollama","model":"qwen2.5:14b","fetchedAt":"2026-08-15T06:00:00Z",
          "ok":true,"error":"" }
        """.data(using: .utf8)!
        let article = try JSONDecoder().decode(ArticleDTO.self, from: ok)
        XCTAssertTrue(article.ok)
        XCTAssertEqual(article.contentVI.components(separatedBy: "\n\n").count, 2)

        // Defensive decode: a minimal/failure payload must not crash — every
        // field falls back to its zero value like every other DTO here.
        let minimal = "{}".data(using: .utf8)!
        let empty = try JSONDecoder().decode(ArticleDTO.self, from: minimal)
        XCTAssertFalse(empty.ok)
        XCTAssertEqual(empty.contentVI, "")
        XCTAssertEqual(empty.error, "")
    }

    func testSavedFeedDTODefaultsMissingArraysToEmpty() throws {
        let json = "{}".data(using: .utf8)!
        let saved = try JSONDecoder().decode(SavedFeedDTO.self, from: json)
        XCTAssertEqual(saved.items, [])
        XCTAssertEqual(saved.repos, [])
    }
}
