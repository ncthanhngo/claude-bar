import XCTest
@testable import ClaudeSwapWidget

final class ClaudeWatchRemoverTests: XCTestCase {

    func testRemovesInstallerBlock() {
        let rc = "export A=1\n\n# Added by Claude Bar\nalias claude=\"claude-watch\"\n"
        XCTAssertEqual(ClaudeWatchRemover.strippedAlias(from: rc), "export A=1\n")
    }

    func testRemovesStrayAliasLine() {
        let rc = "export A=1\n  alias claude=\"claude-watch\"\nexport B=2\n"
        XCTAssertEqual(ClaudeWatchRemover.strippedAlias(from: rc), "export A=1\nexport B=2\n")
    }

    func testRemovesLegacyClaudeBarWatchAlias() {
        let rc = "x\n\n# Added by Claude Bar\nalias claude=\"claude-bar-watch\"\n"
        XCTAssertEqual(ClaudeWatchRemover.strippedAlias(from: rc), "x\n")
    }

    func testKeepsUserOwnClaudeAliasAndUnrelatedMarker() {
        let rc = "# Added by Claude Bar\nalias claude=\"claude --verbose\"\n"
        XCTAssertNil(ClaudeWatchRemover.strippedAlias(from: rc))
    }

    func testNilWhenNothingToRemove() {
        XCTAssertNil(ClaudeWatchRemover.strippedAlias(from: "export A=1\n"))
    }

    func testRemovesBothBlocksWrittenTwice() {
        let block = "\n# Added by Claude Bar\nalias claude=\"claude-watch\"\n"
        XCTAssertEqual(ClaudeWatchRemover.strippedAlias(from: "a\n" + block + block), "a\n")
    }
}
