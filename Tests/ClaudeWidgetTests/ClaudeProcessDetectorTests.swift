import XCTest
@testable import ClaudeWidget

final class ClaudeProcessDetectorTests: XCTestCase {

    // MARK: - isClaudeCLI basename rule

    func testAcceptsExactBasenameClaude() {
        XCTAssertTrue(ClaudeProcessDetector.isClaudeCLI(executablePath: "/usr/local/bin/claude"))
        XCTAssertTrue(ClaudeProcessDetector.isClaudeCLI(executablePath: "/opt/homebrew/bin/claude"))
        XCTAssertTrue(ClaudeProcessDetector.isClaudeCLI(
            executablePath: "/Users/soi/.vscode/extensions/anthropic.claude-code-2.1.143/resources/native-binary/claude"))
        XCTAssertTrue(ClaudeProcessDetector.isClaudeCLI(
            executablePath: "/Users/soi/.nvm/versions/node/v24/bin/claude"))
    }

    func testRejectsClaudeAppDesktopHelpers() {
        // Path basename is "Claude" (capital), not "claude" — must not match.
        XCTAssertFalse(ClaudeProcessDetector.isClaudeCLI(
            executablePath: "/Applications/Claude.app/Contents/Frameworks/Claude"))
    }

    func testRejectsShipItUpdater() {
        XCTAssertFalse(ClaudeProcessDetector.isClaudeCLI(
            executablePath: "/Applications/Claude.app/Contents/Frameworks/Squirrel.framework/Resources/ShipIt"))
    }

    func testRejectsClaudeWidgetItself() {
        XCTAssertFalse(ClaudeProcessDetector.isClaudeCLI(
            executablePath: "/Applications/Claude Widget.app/Contents/MacOS/ClaudeWidget"))
    }

    func testRejectsArbitraryBasename() {
        XCTAssertFalse(ClaudeProcessDetector.isClaudeCLI(executablePath: "/bin/bash"))
        XCTAssertFalse(ClaudeProcessDetector.isClaudeCLI(executablePath: ""))
        XCTAssertFalse(ClaudeProcessDetector.isClaudeCLI(executablePath: "claude.js"))
        XCTAssertFalse(ClaudeProcessDetector.isClaudeCLI(executablePath: "myclaude"))
    }

    // MARK: - parsePgrepOutput

    func testParseEmptyOutput() {
        XCTAssertEqual(
            ClaudeProcessDetector.parsePgrepOutput("", excludingPID: 0),
            []
        )
    }

    func testParseSingleClaudeCLI() {
        let raw = "1787 /Users/soi/.vscode/extensions/anthropic.claude-code-2.1.143/resources/native-binary/claude --foo\n"
        XCTAssertEqual(
            ClaudeProcessDetector.parsePgrepOutput(raw, excludingPID: 0),
            [1787]
        )
    }

    func testParseMixedOutputFiltersNonCLI() {
        // Real-world sample: VSCode extension CLI + Claude.app helpers + ShipIt.
        let raw = """
1787 /Users/soi/.vscode/extensions/anthropic.claude-code-2.1.143/resources/native-binary/claude --output-format stream-json
15483 /Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper --type=utility
15928 /Applications/Claude.app/Contents/Frameworks/Squirrel.framework/Resources/ShipIt com.anthropic.claudefordesktop.ShipIt
16944 /Users/soi/.vscode/extensions/anthropic.claude-code-2.1.143/resources/native-binary/claude --debug
"""
        XCTAssertEqual(
            ClaudeProcessDetector.parsePgrepOutput(raw, excludingPID: 0),
            [1787, 16944]
        )
    }

    func testParseExcludesOwnPID() {
        let raw = """
1787 /opt/homebrew/bin/claude
9999 /opt/homebrew/bin/claude
"""
        XCTAssertEqual(
            ClaudeProcessDetector.parsePgrepOutput(raw, excludingPID: 9999),
            [1787]
        )
    }

    func testParseHandlesGarbageLine() {
        let raw = """
not-a-pid foo bar
1787 /opt/homebrew/bin/claude
single-token-line
"""
        XCTAssertEqual(
            ClaudeProcessDetector.parsePgrepOutput(raw, excludingPID: 0),
            [1787]
        )
    }
}
