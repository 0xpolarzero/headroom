import XCTest
@testable import Headroom

final class ClaudeAccountsTests: XCTestCase {
    // MARK: Accounts

    func testKeychainServiceMatchesClaudeCode() {
        XCTAssertEqual(ClaudeProvider.keychainService(configDir: nil), "Claude Code-credentials")
        // sha256("/Users/x/.claude-accounts/Pro")[0..<8], as Claude Code 2.1.310 names it.
        XCTAssertEqual(ClaudeProvider.keychainService(configDir: "/Users/x/.claude-accounts/Pro"), "Claude Code-credentials-71aaf74d")
    }

    func testFolders() {
        let main = ClaudeAccount(id: "main"), pro = ClaudeAccount(id: "Pro")
        XCTAssertTrue(main.appDataDir.hasSuffix("/Library/Application Support/Claude"))
        XCTAssertNil(main.cliConfigDir)
        XCTAssertTrue(pro.appDataDir.hasSuffix("/Library/Application Support/Claude-Pro"))
        XCTAssertTrue(pro.cliConfigDir!.hasSuffix("/.claude-accounts/Pro"))
    }

    func testSlug() {
        XCTAssertEqual(ClaudeAccount.slug("Pro"), "Pro")
        XCTAssertEqual(ClaudeAccount.slug("  my work/acct "), "my-work-acct")
        XCTAssertEqual(ClaudeAccount.slug("../"), "")
    }

    func testNormalizeKeepsOneMainAndAddsAccounts() {
        var c = ClaudeAccountsConfig()
        c.accounts = [ClaudeAccount(id: "Pro")]
        c.order = ["gone", "main", "main"]
        c.normalize()
        XCTAssertEqual(c.order, ["main", "Pro"])
        c.order = ["Pro"]
        c.normalize()
        XCTAssertEqual(c.order, ["main", "Pro"])
        XCTAssertEqual(c.ordered.map(\.id), ["main", "Pro"])
    }

    // MARK: Where new sessions go

    func testRecommendation() {
        // First in the order below the threshold.
        XCTAssertEqual(AppModel.recommended([40, 10], threshold: 85), 0)
        XCTAssertEqual(AppModel.recommended([88, 10], threshold: 85), 1)
        // All above it: the least used that isn't full.
        XCTAssertEqual(AppModel.recommended([90, 96], threshold: 85), 0)
        XCTAssertEqual(AppModel.recommended([100, 96], threshold: 85), 1)
        // All full, or nothing known.
        XCTAssertNil(AppModel.recommended([100, 100], threshold: 85))
        XCTAssertNil(AppModel.recommended([nil, nil], threshold: 85))
        // An account without numbers is skipped, not chosen.
        XCTAssertEqual(AppModel.recommended([nil, 30], threshold: 85), 1)
    }

    // MARK: Session presets

    private func preset(_ id: String, _ name: String) -> SessionPresets.Preset { ["id": id, "name": name] }

    func testPresetsMergeNewestFileWins() {
        let old = SessionPresets.Source(accountID: "main", modified: Date(timeIntervalSince1970: 1),
                                        presets: [preset("a", "A"), preset("b", "B")])
        let new = SessionPresets.Source(accountID: "Pro", modified: Date(timeIntervalSince1970: 2),
                                        presets: [preset("b", "B renamed"), preset("c", "C")])
        let merged = SessionPresets.merge([old, new], deleted: [])
        XCTAssertEqual(merged.map { $0["id"] as? String }, ["b", "c", "a"])
        XCTAssertEqual(merged.first?["name"] as? String, "B renamed")
    }

    func testPresetDeletedInOneCopyIsDeletedEverywhere() {
        let main = SessionPresets.Source(accountID: "main", modified: .now, presets: [preset("a", "A")])
        let pro = SessionPresets.Source(accountID: "Pro", modified: .now, presets: [preset("a", "A"), preset("b", "B")])
        // Both had a and b at the last sync; main no longer has b.
        let deleted = SessionPresets.deletions([main, pro], known: ["main": ["a", "b"], "Pro": ["a", "b"]])
        XCTAssertEqual(deleted, ["b"])
        XCTAssertEqual(SessionPresets.merge([main, pro], deleted: deleted).map { $0["id"] as? String }, ["a"])
        // Never seen before: a new preset, not a deletion.
        XCTAssertEqual(SessionPresets.deletions([main, pro], known: [:]), [])
    }

    // MARK: Processes

    func testReadsOwnArguments() {
        let args = ClaudeApps.arguments(of: getpid())
        XCTAssertEqual(args?.count, CommandLine.arguments.count)
        XCTAssertEqual(args?.last, CommandLine.arguments.last)
    }
}
