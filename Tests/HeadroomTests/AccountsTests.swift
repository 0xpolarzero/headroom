import XCTest
@testable import Headroom

final class AccountsTests: XCTestCase {
    private func keys(_ config: AccountsConfig, _ provider: ProviderID) -> [String] { config.pool(provider).map(\.key) }

    // MARK: Features

    func testFeaturesOfAnOlderInstallFollowThePlugin() {
        XCTAssertEqual(Feature.initial(pluginInstalled: true), [.limits, .agents])
        XCTAssertEqual(Feature.initial(pluginInstalled: false), [.limits])
    }

    // MARK: Accounts

    func testEveryProviderHasOneMainAccount() {
        let config = AccountsConfig()
        for provider in ProviderID.allCases { XCTAssertEqual(keys(config, provider), ["main"]) }
    }

    func testWhereEachAccountKeepsItsLogin() {
        for provider in ProviderID.allCases {
            XCTAssertNil(Account.main(provider).folder)
            XCTAssertEqual(Account.main(provider).keychainItem("zai-api-key"), "zai-api-key")
        }
        XCTAssertTrue(Account(provider: .claude, key: "Pro").folder!.hasSuffix("/.claude-accounts/Pro"))
        XCTAssertTrue(Account(provider: .codex, key: "work").folder!.hasSuffix("/.codex-accounts/work"))
        XCTAssertNil(Account(provider: .zai, key: "work").folder)
        XCTAssertEqual(Account(provider: .zai, key: "work").keychainItem("zai-api-key"), "zai-api-key.work")
        XCTAssertEqual(Account(provider: .codex, key: "work").id, "codex.work")
        // Claude accounts keep the folders they had before pools.
        XCTAssertEqual(ClaudeAccount(id: "Pro").cliConfigDir, Account(provider: .claude, key: "Pro").folder)
    }

    func testAddingGoesToTheEndOfItsOwnPool() {
        var config = AccountsConfig()
        XCTAssertEqual(config.add(.codex, name: "work")?.id, "codex.work")
        XCTAssertEqual(config.add(.claude, name: "my pro")?.key, "my-pro")
        XCTAssertEqual(config.add(.codex, name: "home")?.id, "codex.home")
        XCTAssertEqual(keys(config, .codex), ["main", "work", "home"])
        XCTAssertEqual(keys(config, .claude), ["main", "my-pro"])
        let claudeEnd = config.accounts.lastIndex { $0.provider == .claude }!
        XCTAssertEqual(config.accounts.firstIndex { $0.provider == .codex }, claudeEnd + 1)
    }

    func testAddingRefusesUnusableAndTakenNames() {
        var config = AccountsConfig()
        XCTAssertNil(config.add(.zai, name: "../"))
        XCTAssertNil(config.add(.zai, name: "Main"))
        XCTAssertNotNil(config.add(.zai, name: "work"))
        XCTAssertNil(config.add(.zai, name: "Work"))
        XCTAssertNotNil(config.add(.codex, name: "work"), "names are per provider")
    }

    func testMovingStaysInsideThePool() {
        var config = AccountsConfig()
        _ = config.add(.codex, name: "a")
        _ = config.add(.zai, name: "x")
        _ = config.add(.codex, name: "b")
        config.move("codex.b", by: -1)
        XCTAssertEqual(keys(config, .codex), ["main", "b", "a"])
        config.move("codex.main", by: 1)
        XCTAssertEqual(keys(config, .codex), ["b", "main", "a"])
        config.move("codex.b", by: -1)   // already first
        XCTAssertEqual(keys(config, .codex), ["b", "main", "a"])
        XCTAssertEqual(keys(config, .zai), ["main", "x"])
    }

    func testMainAccountsCantBeRemoved() {
        var config = AccountsConfig()
        _ = config.add(.openrouter, name: "team")
        config.remove("openrouter.main")
        config.remove("openrouter.team")
        XCTAssertEqual(keys(config, .openrouter), ["main"])
    }

    func testNormalizeDropsDuplicatesAndRestoresMain() throws {
        let json = #"{"accounts":[{"provider":"codex","key":"a","addedAt":1},{"provider":"codex","key":"a","addedAt":2}],"weeklyThreshold":0.5}"#
        let config = try JSONDecoder.headroom.decode(AccountsConfig.self, from: Data(json.utf8))
        XCTAssertEqual(keys(config, .codex), ["main", "a"])
        XCTAssertEqual(config.pool(.codex)[1].addedAt, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(config.weeklyThreshold, 0.5)
        XCTAssertEqual(config.sessionThreshold, AccountsConfig.defaultThreshold)
        XCTAssertEqual(keys(config, .zai), ["main"])
    }

    // MARK: Migration and files

    private let legacyJSON = #"""
    {"accounts":[{"id":"Pro","addedAt":100},{"id":"Team","addedAt":200}],"order":["Pro","main","Team"],
     "sessionThreshold":0.75,"weeklyThreshold":0.95}
    """#

    func testMigratingTheOldClaudeListKeepsItsOrderAndThresholds() throws {
        let old = try JSONDecoder.headroom.decode(ClaudeAccountsConfig.self, from: Data(legacyJSON.utf8))
        let config = AccountsConfig(migrating: old)
        XCTAssertEqual(keys(config, .claude), ["Pro", "main", "Team"])
        XCTAssertEqual(config.pool(.claude)[0].addedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(config.sessionThreshold, 0.75)
        XCTAssertEqual(config.weeklyThreshold, 0.95)
        for provider in ProviderID.allCases where provider != .claude { XCTAssertEqual(keys(config, provider), ["main"]) }
        // The runners' view of it is the old list.
        let claude = ClaudeAccountsConfig(config)
        XCTAssertEqual(claude.order, old.order)
        XCTAssertEqual(claude.accounts, old.accounts)
        XCTAssertEqual(claude.sessionThreshold, 0.75)
    }

    func testLoadMigratesUntilSavedThenReadsItsOwnFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("accounts.json"), legacy = dir.appendingPathComponent("claude-accounts.json")

        XCTAssertEqual(AccountsConfig.load(from: url, legacy: legacy), AccountsConfig())
        try Data(legacyJSON.utf8).write(to: legacy)
        var config = AccountsConfig.load(from: url, legacy: legacy)
        XCTAssertEqual(keys(config, .claude), ["Pro", "main", "Team"])

        _ = config.add(.codex, name: "work")
        try config.save(to: url)
        XCTAssertEqual(AccountsConfig.load(from: url, legacy: legacy), config)
        XCTAssertEqual(try Data(contentsOf: legacy), Data(legacyJSON.utf8), "the old file stays as it was")
    }

    func testReplacingTheClaudePoolLeavesOtherProvidersAlone() {
        var config = AccountsConfig()
        _ = config.add(.codex, name: "work")
        var claude = ClaudeAccountsConfig(config)
        claude.accounts.append(ClaudeAccount(id: "Pro"))
        claude.order = ["Pro", "main"]
        claude.weeklyThreshold = 0.5
        config.replaceClaudePool(with: claude)
        XCTAssertEqual(keys(config, .claude), ["Pro", "main"])
        XCTAssertEqual(keys(config, .codex), ["main", "work"])
        XCTAssertEqual(config.weeklyThreshold, 0.5)
        XCTAssertEqual(config.accounts.first?.provider, .claude, "the Claude pool keeps its place")
    }
}
