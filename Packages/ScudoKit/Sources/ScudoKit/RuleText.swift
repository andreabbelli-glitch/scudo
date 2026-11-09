import Foundation

/// Helpers to read filter list text.
public enum RuleText {
    /// Splits a filter list into rule lines, dropping blanks, `!` comments and
    /// the `[Adblock Plus 2.0]` style header. Lines starting with `#` are kept
    /// because `##selector` is a valid element hiding rule.
    public static func lines(of text: String) -> [String] {
        var text = text
        text.makeContiguousUTF8()
        var result: [String] = []
        result.reserveCapacity(text.utf8.count / 40)
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("!"), !isHeader(line) else { continue }
            result.append(line)
        }
        return result
    }

    /// Reads `! Title:` and `! Version:` from the list header.
    public static func metadata(of text: String) -> (title: String?, version: String?) {
        var title: String?
        var version: String?
        for raw in text.split(whereSeparator: \.isNewline).prefix(60) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("!") else {
                if isHeader(line) || line.isEmpty { continue }
                break
            }
            if title == nil, let value = value(of: "Title", in: line) { title = value }
            if version == nil, let value = value(of: "Version", in: line) { version = value }
        }
        return (title, version)
    }

    /// True for exception rules: `@@||example.com^`, `example.com#@#.banner`…
    public static func isException(_ line: String) -> Bool {
        line.hasPrefix("@@") || ["#@#", "#@$#", "#@%#", "#@?#", "#@?$#"].contains { line.contains($0) }
    }

    /// Rough check that a download is a filter list and not, say, an HTML
    /// error page served with status 200.
    public static func looksLikeFilterList(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let head = String(decoding: data.prefix(512), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return !(head.hasPrefix("<!doctype") || head.hasPrefix("<html") || head.hasPrefix("<?xml"))
    }

    private static func isHeader(_ line: String) -> Bool {
        line.hasPrefix("[") && line.hasSuffix("]") && line.lowercased().contains("adblock")
    }

    private static func value(of key: String, in line: String) -> String? {
        // "! Title: AdGuard Base filter"
        let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
        guard body.lowercased().hasPrefix(key.lowercased() + ":") else { return nil }
        let value = body.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

/// Turns what the user types ("https://www.Example.com/page") into the domain
/// used by allowlist rules ("example.com").
public enum DomainInput {
    public static func normalize(_ input: String) -> String? {
        var host = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = host.range(of: "://") {
            host = String(host[scheme.upperBound...])
        }
        if let end = host.firstIndex(where: { "/?#".contains($0) }) {
            host = String(host[..<end])
        }
        if let at = host.lastIndex(of: "@") {
            host = String(host[host.index(after: at)...])
        }
        if let colon = host.lastIndex(of: ":") {
            host = String(host[..<colon])
        }
        for prefix in ["*.", "www."] where host.hasPrefix(prefix) {
            host.removeFirst(prefix.count)
        }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))

        guard host.count <= 253, host.contains("."), !host.contains("..") else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        for label in labels {
            guard !label.isEmpty, label.count <= 63,
                  !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.unicodeScalars.allSatisfy(allowed.contains)
            else { return nil }
        }
        // The last label (TLD) cannot be purely numeric.
        if let tld = labels.last, tld.allSatisfy(\.isNumber) { return nil }
        return host
    }
}
