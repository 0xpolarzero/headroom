import XCTest
@testable import Headroom

final class ProviderMappingTests: XCTestCase {
    private func obj(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    // MARK: Codex

    func testCodexClassifiesByWindowLength() {
        // Weekly-only plan reports its weekly window in the primary slot.
        let root = obj("""
        {"plan_type":"prolite","rate_limit":{"primary_window":{"used_percent":42,"limit_window_seconds":604800,"reset_after_seconds":3600}}}
        """)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let w = CodexProvider.windows(from: root, now: now)
        XCTAssertEqual(w.map(\.label), ["Weekly"])
        XCTAssertEqual(w[0].usedPercent, 42)
        XCTAssertEqual(w[0].resetsAt, now.addingTimeInterval(3600))
        XCTAssertEqual(CodexProvider.planName("prolite"), "Pro 100")
        XCTAssertEqual(CodexProvider.planName("pro"), "Pro 200")
        XCTAssertEqual(CodexProvider.planName("plus"), "Plus")
    }

    func testCodexSlotFallbackAndResetAt() {
        let root = obj("""
        {"rate_limit":{"primary_window":{"used_percent":10,"reset_at":2000000000},
                       "secondary_window":{"used_percent":55.5,"reset_at":2000600000}}}
        """)
        let w = CodexProvider.windows(from: root)
        XCTAssertEqual(w.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(w[1].usedPercent, 55.5)
        XCTAssertEqual(w[0].resetsAt, Date(timeIntervalSince1970: 2_000_000_000))
    }

    // MARK: Antigravity

    func testAntigravityBucketsMergeAcrossHosts() {
        let prod = obj("""
        {"groups":[{"displayName":"Gemini","buckets":[
          {"bucketId":"gemini-5h","remainingFraction":0.75,"resetTime":"2026-10-26T15:00:00Z"},
          {"bucketId":"gemini-weekly","remainingFraction":0.5}]}]}
        """)
        let daily = obj("""
        {"response":{"groups":[{"displayName":"Claude","buckets":[
          {"bucketId":"3p-5h","remainingFraction":1},
          {"bucketId":"3p-weekly"},
          {"bucketId":"gemini-5h","remainingFraction":0.1}]},
          {"displayName":"Gemini 4 Argon","buckets":[{"bucketId":"argon-weekly","remainingFraction":0.2}]}]}}
        """)
        let w = AntigravityProvider.windows(fromSummaries: [prod, daily])
        XCTAssertEqual(w.map(\.label), ["Session", "Weekly", "Claude"])
        XCTAssertEqual(w[0].usedPercent ?? -1, 25, accuracy: 0.001)   // first host wins
        XCTAssertEqual(w[1].usedPercent ?? -1, 50, accuracy: 0.001)
        XCTAssertEqual(w[2].usedPercent ?? -1, 0, accuracy: 0.001)
        XCTAssertNotNil(w[0].resetsAt)
    }

    func testAntigravityPlanAndTokenParsing() {
        XCTAssertEqual(AntigravityProvider.plan(fromLoadCodeAssist: obj(#"{"paidTier":{"id":"g1-ultra-tier","name":"x"}}"#)), "Ultra")
        XCTAssertEqual(AntigravityProvider.plan(fromLoadCodeAssist: obj(#"{"currentTier":{"name":"Google AI Pro"}}"#)), "Pro")
        let t = AntigravityProvider.token(from: obj(#"{"token":{"accessToken":"a","refresh_token":"r","expiry":"2026-10-26T12:00:00Z"}}"#))
        XCTAssertEqual(t?.access, "a")
        XCTAssertEqual(t?.refresh, "r")
        XCTAssertNotNil(t?.expiry)
    }

    // MARK: Z.ai

    func testZAIWindows() throws {
        let root = obj("""
        {"success":true,"data":{"limits":[
          {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":30,"nextResetTime":1770648402389},
          {"type":"CREDIT_LIMIT","unit":6,"number":1,"percentage":12,"nextResetTime":1771000000000},
          {"type":"TIME_LIMIT","unit":5,"number":1,"usage":100,"currentValue":25}]}}
        """)
        let w = try ZAIProvider.windows(from: root)
        XCTAssertEqual(w.map(\.label), ["Session", "Weekly", "Web Searches"])
        XCTAssertEqual(w[0].usedPercent, 30)
        XCTAssertEqual(w[0].resetsAt, Date(timeIntervalSince1970: 1_770_648_402.389))
        XCTAssertEqual(w[2].usedPercent, 25)
        XCTAssertEqual(w[2].detail, "25 / 100")
        XCTAssertEqual(ZAIProvider.plan(from: obj(#"{"data":[{"productName":"GLM Coding Max"}]}"#)), "GLM Coding Max")
    }

    func testZAIFailureMessage() {
        XCTAssertThrowsError(try ZAIProvider.windows(from: obj(#"{"success":false,"msg":"no plan"}"#))) { error in
            XCTAssertEqual((error as? ProviderError)?.errorDescription, "no plan")
        }
    }
}

final class FormatTests: XCTestCase {
    func testDurations() {
        XCTAssertEqual(Format.duration(30), "1m")
        XCTAssertEqual(Format.duration(12 * 60), "12m")
        XCTAssertEqual(Format.duration(2 * 3600 + 15 * 60), "2h 15m")
        XCTAssertEqual(Format.duration(3 * 3600), "3h")
        XCTAssertEqual(Format.duration(3 * 86400 + 4 * 3600 + 59), "3d 4h")
        let now = Date()
        XCTAssertEqual(Format.resets(now.addingTimeInterval(-5), now: now), "Resetting now")
        XCTAssertEqual(Format.used(UsageWindow(label: "Session", usedPercent: 41.6)), "42% used")
    }

    func testCodexTokenExpiry() {
        func jwt(exp: Double) -> String {
            let payload = Data(#"{"exp":\#(exp)}"#.utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            return "e30.\(payload).sig"
        }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertTrue(CodexProvider.isExpiring(jwt(exp: 2_000_000_030), now: now))
        XCTAssertFalse(CodexProvider.isExpiring(jwt(exp: 2_000_003_600), now: now))
        XCTAssertFalse(CodexProvider.isExpiring("not-a-jwt", now: now))
    }
}

final class ClaudeMappingTests: XCTestCase {
    func testClaudeWindowsAndPlan() throws {
        let root = try JSONSerialization.jsonObject(with: Data("""
        {"five_hour":{"utilization":6.0,"resets_at":"2026-10-26T19:59:59.943648+00:00"},
         "seven_day":{"utilization":35,"resets_at":"2026-10-30T10:00:00+00:00"},
         "seven_day_opus":null,"seven_day_sonnet":{"utilization":12.5,"resets_at":null}}
        """.utf8)) as! [String: Any]
        let w = ClaudeProvider.windows(from: root)
        XCTAssertEqual(w.map(\.label), ["Session", "Weekly", "Sonnet Weekly"])
        XCTAssertEqual(w[0].usedPercent, 6)
        XCTAssertEqual(w[0].resetsAt?.timeIntervalSince1970 ?? 0, 1_793_044_799.943, accuracy: 0.01)
        XCTAssertNil(w[2].resetsAt)

        XCTAssertEqual(ClaudeProvider.planName(type: "max", tier: "default_claude_max_20x"), "Max 20x")
        XCTAssertEqual(ClaudeProvider.planName(type: "pro", tier: "default_claude_ai"), "Pro")
        let creds = ClaudeProvider.credentials(from: #"{"claudeAiOauth":{"accessToken":"t","expiresAt":1793044799000,"subscriptionType":"max"}}"#)
        XCTAssertEqual(creds?.accessToken, "t")
        XCTAssertEqual(creds?.plan, "Max")
        XCTAssertNil(ClaudeProvider.credentials(from: "{}"))
    }
}
