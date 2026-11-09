import ContentBlockerConverter
import Foundation
import ScudoShared

/// Result of converting the filter rules of one content blocker.
public struct ConversionOutput: Sendable, Equatable {
    /// Safari content blocking JSON, always a non-empty array.
    public let json: String
    public let safariRuleCount: Int
    public let sourceRuleCount: Int
    /// Rules dropped to stay within Safari's limits.
    public let discardedRuleCount: Int
    /// Rules the converter could not translate (unsupported syntax).
    public let unconvertibleRuleCount: Int
}

/// Thin wrapper around AdGuard's `ContentBlockerConverter`.
///
/// A content blocker is produced in two steps:
/// 1. ``convert(rules:)`` turns the filter lists into Safari JSON (slow,
///    seconds for big lists), cached until the lists change;
/// 2. ``finalize(base:allowlistDomains:)`` appends the user's allowlist
///    (instant), so editing the allowlist never requires a full conversion.
///
/// Appending the allowlist last is also a safety measure: when a list exceeds
/// the limits the converter drops the *last* rules, which are exactly the
/// document-level exceptions. Converting them separately guarantees the
/// user's allowlist always survives.
public enum RuleConverter {
    /// Upper bound for the JSON of a single content blocker.
    ///
    /// Since iOS 17 the rules are loaded inside the extension process, which
    /// is killed above its memory limit: too big a file makes Safari fail with
    /// `SFErrorDomain 3` (Apple feedback FB13282146, AdguardTeam/SafariConverterLib#56).
    /// The values are the ones AdGuard for iOS ships with: ~10 MB on iOS
    /// 17.0–17.1, ~19 MB from iOS 17.2. Rules beyond the limit are dropped and
    /// reported as "discarded".
    public static var maxJSONBytes: Int {
        #if os(iOS)
        if #available(iOS 17.2, *) {
            return 19_000_000
        }
        return 10_000_000
        #else
        return 19_000_000
        #endif
    }

    /// Room left in every blocker for the allowlist appended by ``finalize(base:allowlistDomains:)``.
    static let allowlistReserveBytes = 64 * 1024

    /// Safari version the rules are produced for (derived from the OS version).
    public static var safariVersion: String { SafariVersion.autodetect().description }

    /// Version of the converter library, part of the blocker fingerprint so
    /// that an app update with a newer converter rebuilds the rules.
    public static var converterVersion: String { ContentBlockerConverterVersion.library }

    /// Converts filter rules (AdBlock/AdGuard syntax) to Safari JSON.
    public static func convert(rules: [String], maxJSONBytes: Int = maxJSONBytes) -> ConversionOutput {
        guard !rules.isEmpty else {
            return ConversionOutput(json: PlaceholderRules.json, safariRuleCount: 0, sourceRuleCount: 0, discardedRuleCount: 0, unconvertibleRuleCount: 0)
        }
        let result = ContentBlockerConverter().convertArray(
            rules: rules,
            safariVersion: SafariVersion.autodetect(),
            advancedBlocking: false,
            maxJsonSizeBytes: max(maxJSONBytes - allowlistReserveBytes, 1024),
            progress: nil
        )
        return ConversionOutput(
            json: result.safariRulesCount > 0 ? result.safariRulesJSON : PlaceholderRules.json,
            safariRuleCount: result.safariRulesCount,
            sourceRuleCount: result.sourceRulesCount,
            discardedRuleCount: result.discardedSafariRules,
            unconvertibleRuleCount: result.errorsCount
        )
    }

    /// Maximum number of rules Safari accepts in one content blocker
    /// (150,000 since Safari 15). Above it Safari rejects the whole blocker.
    public static var ruleLimit: Int { SafariVersion.autodetect().rulesLimit }

    /// Appends the rules disabling blocking on `allowlistDomains` to an
    /// already converted blocker.
    ///
    /// If the base already uses all of Safari's rule budget (the converter
    /// truncates at exactly `ruleLimit`), room for the allowlist is made by
    /// dropping rules from the *front* of the base — generic element hiding —
    /// and never the exceptions at its end.
    public static func finalize(base: ConversionOutput, allowlistDomains: [String], ruleLimit: Int = RuleConverter.ruleLimit) -> ConversionOutput {
        guard !allowlistDomains.isEmpty else { return base }
        let allowlist = ContentBlockerConverter().convertArray(
            rules: allowlistDomains.map(allowlistRule(for:)),
            safariVersion: SafariVersion.autodetect(),
            advancedBlocking: false,
            maxJsonSizeBytes: nil,
            progress: nil
        )
        guard allowlist.safariRulesCount > 0 else { return base }

        var baseJSON: String? = base.safariRuleCount > 0 ? base.json : nil
        var baseCount = base.safariRuleCount
        var discarded = base.discardedRuleCount
        let overflow = baseCount + allowlist.safariRulesCount - ruleLimit
        if overflow > 0, let json = baseJSON {
            let trimmed = dropLeadingRules(overflow, from: json)
            baseJSON = trimmed.json
            baseCount -= trimmed.dropped
            discarded += trimmed.dropped
        }

        return ConversionOutput(
            json: mergeJSONArrays(baseJSON, allowlist.safariRulesJSON),
            safariRuleCount: baseCount + allowlist.safariRulesCount,
            sourceRuleCount: base.sourceRuleCount + allowlist.sourceRulesCount,
            discardedRuleCount: discarded + allowlist.discardedSafariRules,
            unconvertibleRuleCount: base.unconvertibleRuleCount + allowlist.errorsCount
        )
    }

    /// Removes the first `count` rules of a Safari JSON array. Only used in
    /// the rare overflow case, so parsing the whole array is acceptable.
    /// Returns `nil` JSON when no rule is left.
    static func dropLeadingRules(_ count: Int, from json: String) -> (json: String?, dropped: Int) {
        guard let rules = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any] else {
            return (json, 0)
        }
        let dropped = min(count, rules.count)
        let remaining = Array(rules.dropFirst(dropped))
        // Without escaping "/" the file keeps its size (url-filters are full of slashes).
        guard !remaining.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: remaining, options: .withoutEscapingSlashes)
        else {
            return (nil, dropped)
        }
        return (String(decoding: data, as: UTF8.self), dropped)
    }

    /// Checks user rules: how many Safari rules they produce and how many
    /// lines cannot be applied by a content blocker (invalid syntax, or
    /// "advanced" rules such as scriptlets that need a web extension).
    public static func check(rules: [String]) -> (safariRuleCount: Int, unsupportedCount: Int) {
        guard !rules.isEmpty else { return (0, 0) }
        let result = ContentBlockerConverter().convertArray(
            rules: rules,
            safariVersion: SafariVersion.autodetect(),
            advancedBlocking: true,
            maxJsonSizeBytes: nil,
            progress: nil
        )
        return (result.safariRulesCount, result.errorsCount + result.advancedRulesCount)
    }

    /// AdGuard rule that disables every content blocker rule on `domain`
    /// and its subdomains.
    public static func allowlistRule(for domain: String) -> String {
        ContentBlockerConverter.createAllowlistRule(by: domain)
    }

    /// Concatenates two JSON arrays given as text (`[a,b]` + `[c]` → `[a,b,c]`)
    /// without re-parsing megabytes of rules. `nil` means "no first array".
    static func mergeJSONArrays(_ first: String?, _ second: String) -> String {
        let tail = second.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first else { return tail }
        let head = first.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.hasPrefix("["), head.hasSuffix("]"), tail.hasPrefix("["), tail.hasSuffix("]") else {
            return head
        }
        let headBody = head.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        let tailBody = tail.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        if headBody.isEmpty { return "[\(tailBody)]" }
        if tailBody.isEmpty { return "[\(headBody)]" }
        return "[\(headBody),\(tailBody)]"
    }
}
