import Foundation
import Testing
@testable import ScudoKit
import ScudoShared

@Suite("Rule converter")
struct RuleConverterTests {
    private func rules(in json: String) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(object as? [[String: Any]])
    }

    private func actionType(_ rule: [String: Any]) -> String? {
        (rule["action"] as? [String: Any])?["type"] as? String
    }

    @Test func convertsNetworkAndCosmeticRules() throws {
        let output = RuleConverter.convert(rules: ["||ads.example.com^", "example.org##.banner"])
        #expect(output.safariRuleCount == 2)
        let parsed = try rules(in: output.json)
        #expect(parsed.map(actionType).sorted { ($0 ?? "") < ($1 ?? "") } == ["block", "css-display-none"])
    }

    @Test func emptyInputProducesPlaceholder() throws {
        let output = RuleConverter.convert(rules: [])
        #expect(output.safariRuleCount == 0)
        #expect(output.json == PlaceholderRules.json)
        #expect(try rules(in: output.json).count == 1)
    }

    @Test func allowlistIsAppendedLast() throws {
        let base = RuleConverter.convert(rules: ["||ads.example.com^", "##.banner"])
        let final = RuleConverter.finalize(base: base, allowlistDomains: ["news.example.it", "shop.example"])
        let parsed = try rules(in: final.json)
        #expect(final.safariRuleCount == base.safariRuleCount + 2)
        #expect(parsed.count == final.safariRuleCount)
        let tail = parsed.suffix(2)
        #expect(tail.allSatisfy { actionType($0) == "ignore-previous-rules" })
        let tailText = String(decoding: try JSONSerialization.data(withJSONObject: Array(tail)), as: UTF8.self)
        #expect(tailText.contains("news.example.it"))
        #expect(tailText.contains("shop.example"))
    }

    @Test func allowlistOnPlaceholderDropsThePlaceholder() throws {
        let final = RuleConverter.finalize(base: RuleConverter.convert(rules: []), allowlistDomains: ["example.com"])
        let parsed = try rules(in: final.json)
        #expect(parsed.count == 1)
        #expect(!final.json.contains("scudo-placeholder"))
    }

    @Test func allowlistNeverPushesABlockerOverTheRuleLimit() throws {
        // A blocker that already uses its whole budget (as after the
        // converter truncates at exactly 150,000 rules).
        let base = RuleConverter.convert(rules: (0..<10).map { "||ads\($0).example.com^" })
        #expect(base.safariRuleCount == 10)

        let final = RuleConverter.finalize(base: base, allowlistDomains: ["a.example", "b.example"], ruleLimit: 10)
        let parsed = try rules(in: final.json)

        #expect(final.safariRuleCount == 10)
        #expect(parsed.count == 10)
        #expect(final.discardedRuleCount == 2)
        // The first rules were dropped, the allowlist is intact at the end.
        // (Dots are escaped in url-filter regexes, so match the bare labels.)
        #expect(!final.json.contains("ads0"))
        #expect(!final.json.contains("ads1"))
        #expect(final.json.contains("ads2"))
        #expect(final.json.contains("ads9"))
        #expect(parsed.suffix(2).allSatisfy { actionType($0) == "ignore-previous-rules" })
    }

    @Test func mergeHandlesEdgeCases() {
        #expect(RuleConverter.mergeJSONArrays("[1,2]", "[3]") == "[1,2,3]")
        #expect(RuleConverter.mergeJSONArrays(nil, " [3] ") == "[3]")
        #expect(RuleConverter.mergeJSONArrays("[]", "[3]") == "[3]")
        #expect(RuleConverter.mergeJSONArrays("[1]", "[]") == "[1]")
    }

    @Test func sizeLimitDiscardsRules() {
        let many = (0..<5000).map { "||ads\($0).example.com^" }
        let limited = RuleConverter.convert(rules: many, maxJSONBytes: RuleConverter.allowlistReserveBytes + 50_000)
        #expect(limited.discardedRuleCount > 0)
        #expect(limited.json.utf8.count <= 50_000)
    }
}
