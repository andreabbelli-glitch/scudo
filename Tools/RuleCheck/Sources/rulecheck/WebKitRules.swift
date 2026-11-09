import Foundation
import ScudoShared
import WebKit

/// Compiles Safari rules with WebKit's `WKContentRuleListStore`: the same
/// parser and compiler Safari runs when a content blocker is reloaded.
@MainActor
final class WebKitRules {
    private let store: WKContentRuleListStore
    private(set) var compiled: [BlockerKind: WKContentRuleList] = [:]
    private(set) var timings: [BlockerKind: TimeInterval] = [:]

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = WKContentRuleListStore(url: directory)
    }

    func compile(_ kind: BlockerKind, json: String) async throws {
        let started = Date()
        let list = try await store.compileContentRuleList(
            forIdentifier: "scudo.\(kind.rawValue)",
            encodedContentRuleList: json
        )
        timings[kind] = Date().timeIntervalSince(started)
        compiled[kind] = list
    }
}
