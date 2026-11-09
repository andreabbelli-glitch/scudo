import Foundation
import ScudoShared

/// Choices made by the user. Persisted as JSON in the shared container.
public struct ScudoSettings: Codable, Equatable, Sendable {
    /// Identifiers of the enabled ``FilterList``s.
    public var enabledFilterIDs: Set<Int>
    /// Sites (registrable domains) where blocking is disabled, e.g. `example.com`.
    public var allowlist: [String]
    /// User rules in AdBlock/AdGuard syntax, one per line.
    public var customRules: String
    /// Whether the app may refresh the lists in the background.
    public var automaticUpdates: Bool

    public init(enabledFilterIDs: Set<Int>, allowlist: [String], customRules: String, automaticUpdates: Bool) {
        self.enabledFilterIDs = enabledFilterIDs
        self.allowlist = allowlist
        self.customRules = customRules
        self.automaticUpdates = automaticUpdates
    }

    public static var defaults: ScudoSettings {
        ScudoSettings(
            enabledFilterIDs: FilterCatalog.defaultEnabledIDs,
            allowlist: [],
            customRules: "",
            automaticUpdates: true
        )
    }

    /// Tolerant decoding: missing keys fall back to the defaults so that
    /// settings written by older versions keep working.
    public init(from decoder: Decoder) throws {
        let defaults = ScudoSettings.defaults
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabledFilterIDs = try container.decodeIfPresent(Set<Int>.self, forKey: .enabledFilterIDs) ?? defaults.enabledFilterIDs
        allowlist = try container.decodeIfPresent([String].self, forKey: .allowlist) ?? defaults.allowlist
        customRules = try container.decodeIfPresent(String.self, forKey: .customRules) ?? defaults.customRules
        automaticUpdates = try container.decodeIfPresent(Bool.self, forKey: .automaticUpdates) ?? defaults.automaticUpdates
    }

    public func isEnabled(_ list: FilterList) -> Bool {
        enabledFilterIDs.contains(list.id)
    }

    public func enabledLists(for kind: BlockerKind) -> [FilterList] {
        FilterCatalog.lists(for: kind).filter(isEnabled)
    }

    /// Custom rules split into lines, without blanks and comments.
    public var customRuleLines: [String] {
        RuleText.lines(of: customRules)
    }

    /// Custom exceptions (`@@…`, `#@#…`): they go into every content blocker,
    /// because each blocker is compiled on its own and an exception only
    /// affects the rules of its own blocker.
    public var customExceptionLines: [String] {
        customRuleLines.filter(RuleText.isException)
    }

    /// Custom blocking rules: they go into the Security blocker.
    public var customBlockingLines: [String] {
        customRuleLines.filter { !RuleText.isException($0) }
    }

    /// Custom rules that belong to the content blocker `kind`.
    public func customRuleLines(for kind: BlockerKind) -> [String] {
        kind == .security ? customRuleLines : customExceptionLines
    }
}

/// Bookkeeping for a downloaded filter list.
public struct FilterRecord: Codable, Equatable, Sendable {
    public var etag: String?
    public var lastModified: String?
    /// SHA-256 of the last downloaded content.
    public var contentHash: String?
    /// When the content last changed.
    public var downloadedAt: Date?
    /// When the server was last contacted successfully (200 or 304).
    public var checkedAt: Date?
    public var title: String?
    public var version: String?
    public var ruleCount: Int?
    public var byteCount: Int?
    public var lastError: String?

    public init() {}
}

/// Bookkeeping for a converted content blocker.
public struct BlockerRecord: Codable, Equatable, Sendable {
    /// Hash of the inputs of the conversion: list contents, custom rules,
    /// converter and Safari versions.
    public var baseFingerprint: String?
    /// `baseFingerprint` plus the allowlist: identifies the JSON handed to Safari.
    public var fingerprint: String?
    /// Fingerprint of the rules Safari last accepted for this extension.
    public var reloadedFingerprint: String?
    public var convertedAt: Date?
    public var builtAt: Date?
    public var reloadedAt: Date?
    /// Rules produced by the filter lists alone (before the allowlist).
    public var baseSafariRuleCount: Int = 0
    /// Rules handed to Safari, allowlist included.
    public var safariRuleCount: Int = 0
    public var sourceRuleCount: Int = 0
    /// Rules dropped because of Safari's limits, as shown to the user
    /// (conversion plus room made for the allowlist).
    public var discardedRuleCount: Int = 0
    /// Rules dropped by the conversion alone (to rebuild from the cache).
    public var baseDiscardedRuleCount: Int = 0
    public var unconvertibleRuleCount: Int = 0
    public var jsonByteCount: Int = 0
    public var includedFilterIDs: [Int] = []
    /// Enabled lists that could not be included because they were never downloaded.
    public var missingFilterIDs: [Int] = []
    public var buildError: String?
    public var reloadError: String?

    public init() {}

    /// True when Safari has not yet loaded the latest rules.
    public var needsReload: Bool {
        fingerprint != nil && fingerprint != reloadedFingerprint
    }
}

/// Everything the app remembers between launches besides the settings.
public struct PersistedState: Codable, Equatable, Sendable {
    public var filters: [String: FilterRecord] = [:]
    public var blockers: [String: BlockerRecord] = [:]
    /// End of the last completed update.
    public var lastUpdateAt: Date?

    public init() {}

    public subscript(filter id: Int) -> FilterRecord {
        get { filters[String(id)] ?? FilterRecord() }
        set { filters[String(id)] = newValue }
    }

    public subscript(blocker kind: BlockerKind) -> BlockerRecord {
        get { blockers[kind.rawValue] ?? BlockerRecord() }
        set { blockers[kind.rawValue] = newValue }
    }
}

/// Progress of a long-running operation, for the UI.
public enum EngineProgress: Sendable, Equatable {
    case downloading(completed: Int, total: Int)
    case converting(BlockerKind)
    case reloading(BlockerKind)
}

/// What the reload callback did for a content blocker.
public enum ReloadOutcome: Sendable, Equatable {
    /// Safari loaded the new rules.
    case reloaded
    /// The extension is switched off in Safari settings: Safari will read the
    /// latest file by itself when the user switches it on.
    case extensionDisabled
}

/// Asks Safari to reload the rules of a content blocker. Injected by the app
/// (it needs SafariServices); tests and the command-line tool pass their own.
public typealias BlockerReloader = @Sendable (BlockerKind) async throws -> ReloadOutcome

/// Result of ``ProtectionEngine/update(forceDownload:forceRebuild:progress:)``.
public struct UpdateSummary: Sendable, Equatable {
    /// Lists whose content changed during this update.
    public var changedFilterIDs: [Int] = []
    /// Lists that could not be downloaded, with the reason.
    public var failedFilters: [Int: String] = [:]
    /// Blockers converted again during this update.
    public var rebuiltBlockers: [BlockerKind] = []
    /// Blockers that could not be converted or reloaded, with the reason.
    public var blockerErrors: [BlockerKind: String] = [:]
    /// True when the update stopped early because the task was cancelled.
    public var wasCancelled = false

    public init() {}

    public var hasErrors: Bool { !failedFilters.isEmpty || !blockerErrors.isEmpty }
}
