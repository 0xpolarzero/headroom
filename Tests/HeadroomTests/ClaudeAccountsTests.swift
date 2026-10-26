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
        // A window that hasn't loaded Headroom's last write saved its older list: not a deletion.
        XCTAssertEqual(SessionPresets.deletions([main, pro], known: ["main": ["a", "b"], "Pro": ["a", "b"]], trusted: ["Pro"]), [])
    }

    // MARK: Processes

    func testReadsOwnArguments() {
        let args = ClaudeApps.arguments(of: getpid())
        XCTAssertEqual(args?.count, CommandLine.arguments.count)
        XCTAssertEqual(args?.last, CommandLine.arguments.last)
    }
}

final class LimitResetsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    func testClaudeResetGrants() {
        let block: [String: Any] = ["eligible": true, "next_grant_id": "g1", "grants": [
            ["id": "g1", "resets_left": 2, "ends_at": "2026-11-05T07:59:00+00:00", "clears": ["five_hour", "seven_day"]],
            ["id": "g0", "resets_left": 0, "ends_at": "2026-11-01T00:00:00+00:00"],
            ["id": "old", "resets_left": 1, "ends_at": "2020-01-01T00:00:00+00:00"],
        ]]
        let r = ClaudeProvider.resetGrants(from: block, now: now)
        XCTAssertEqual(r?.count, 2)
        XCTAssertEqual(r?.expiries.count, 2)
        XCTAssertNil(ClaudeProvider.resetGrants(from: NSNull()))
        XCTAssertEqual(ClaudeProvider.resetGrants(from: ["eligible": false, "grants": block["grants"]!], now: now)?.count, 0)
        XCTAssertNil(ClaudeProvider.resetGrants(from: ["eligible": true, "grants": [["id": "x"]]], now: now))   // malformed
    }

    func testCodexResetCredits() {
        let r = CodexProvider.resetCredits(from: ["available_count": 2, "credits": [
            ["status": "available", "expires_at": "2026-11-03T10:00:00Z"],
            ["expires_at": 1_793_500_000],
            ["status": "consumed", "expires_at": "2026-11-01T10:00:00Z"],
        ]])
        XCTAssertEqual(r?.count, 2)
        XCTAssertEqual(r?.expiries.count, 2)
        XCTAssertEqual(CodexProvider.resetCredits(from: ["available_count": 1])?.expiries, [])
        XCTAssertNil(CodexProvider.resetCredits(from: ["available_count": NSNull()]))
    }

    func testExpiredResetsDrop() {
        let r = LimitResets(count: 3, expiries: [now.addingTimeInterval(-10), now.addingTimeInterval(3600), now.addingTimeInterval(3600)])
        XCTAssertEqual(r.current(now: now), LimitResets(count: 2, expiries: [now.addingTimeInterval(3600), now.addingTimeInterval(3600)]))
    }

    func testTooltipGroupsSameDeadline() {
        let r = LimitResets(count: 3, expiries: [now.addingTimeInterval(3600), now.addingTimeInterval(3600), now.addingTimeInterval(86400 * 3)])
        let text = ResetBadge.tooltip(r, now: now)
        XCTAssertTrue(text.hasPrefix("3 limit resets to spend. Expire 2 in 1h"), text)
        XCTAssertTrue(text.contains("in 3d"), text)
    }
}
