import CryptoKit
import Foundation
import os
import ScudoShared

/// Downloads the enabled filter lists, converts them into Safari content
/// blocking rules and asks Safari to reload the extensions whose rules changed.
///
/// All operations are serialized: an update requested while another one is
/// running starts when the first one ends (and sees the latest settings).
public actor ProtectionEngine {
    public nonisolated let store: ScudoStore
    private let downloader: FilterDownloader
    private let reloader: BlockerReloader?
    private let logger = Logger(subsystem: "Scudo", category: "ProtectionEngine")

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(store: ScudoStore, session: URLSession = .shared, reloader: BlockerReloader? = nil) {
        self.store = store
        self.downloader = FilterDownloader(session: session)
        self.reloader = reloader
    }

    // MARK: Settings and state

    public func settings() -> ScudoSettings {
        store.loadSettings()
    }

    public func save(_ settings: ScudoSettings) async throws {
        await acquire()
        defer { release() }
        try store.save(settings)
    }

    public func state() -> PersistedState {
        store.loadState()
    }

    // MARK: Operations

    /// Brings every content blocker up to date with the settings.
    ///
    /// - Parameters:
    ///   - forceDownload: download every list even if the server says it did not change.
    ///   - forceRebuild: convert every blocker even if its inputs did not change.
    ///   - skipDownload: only use lists already on disk (e.g. after editing the
    ///     allowlist); lists never downloaded are still fetched.
    public func update(
        forceDownload: Bool = false,
        forceRebuild: Bool = false,
        skipDownload: Bool = false,
        progress: (@Sendable (EngineProgress) -> Void)? = nil
    ) async -> UpdateSummary {
        await acquire()
        defer { release() }

        var summary = UpdateSummary()
        let settings = store.loadSettings()
        var state = store.loadState()
        let enabled = FilterCatalog.all.filter(settings.isEnabled)
        let toDownload = skipDownload ? enabled.filter { !store.hasFilter(id: $0.id) } : enabled

        await download(toDownload, force: forceDownload, state: &state, summary: &summary, progress: progress)
        persist(state)

        for kind in BlockerKind.allCases {
            if summary.wasCancelled || Task.isCancelled {
                summary.wasCancelled = true
                break
            }
            build(kind, settings: settings, state: &state, forceConversion: forceRebuild, summary: &summary, progress: progress)
            persist(state)
        }

        if !summary.wasCancelled {
            await reload(pendingKinds(in: state), state: &state, summary: &summary, progress: progress)
        }
        if !summary.wasCancelled && !skipDownload {
            state.lastUpdateAt = Date()
        }
        persist(state)
        logger.info("Update finished: \(summary.rebuiltBlockers.count) blockers rebuilt, \(summary.failedFilters.count) download errors")
        return summary
    }

    /// Asks Safari to load the rules of the extensions that have not loaded
    /// the latest ones yet (e.g. an earlier reload failed or was interrupted).
    public func reloadPending(progress: (@Sendable (EngineProgress) -> Void)? = nil) async -> UpdateSummary {
        await acquire()
        defer { release() }
        var summary = UpdateSummary()
        var state = store.loadState()
        await reload(pendingKinds(in: state), state: &state, summary: &summary, progress: progress)
        persist(state)
        return summary
    }

    /// Asks Safari to reload the given extensions even if their rules did not
    /// change, e.g. right after the user switched them on in Settings.
    public func reload(_ kinds: [BlockerKind], progress: (@Sendable (EngineProgress) -> Void)? = nil) async -> UpdateSummary {
        await acquire()
        defer { release() }
        var summary = UpdateSummary()
        var state = store.loadState()
        await reload(kinds, state: &state, summary: &summary, progress: progress)
        persist(state)
        return summary
    }

    // MARK: Steps

    private func download(
        _ lists: [FilterList],
        force: Bool,
        state: inout PersistedState,
        summary: inout UpdateSummary,
        progress: (@Sendable (EngineProgress) -> Void)?
    ) async {
        guard !lists.isEmpty else { return }
        progress?(.downloading(completed: 0, total: lists.count))

        let requests = lists.map { list in
            let record = state[filter: list.id]
            // Revalidate only when the cached copy is really on disk.
            let revalidate = !force && store.hasFilter(id: list.id)
            return (list, revalidate ? record.etag : nil, revalidate ? record.lastModified : nil)
        }
        let downloader = self.downloader
        let total = lists.count

        let results = await withTaskGroup(of: (FilterList, Result<FilterDownloader.Outcome, any Error>).self) { group in
            for (list, etag, lastModified) in requests {
                group.addTask {
                    do {
                        return (list, .success(try await downloader.fetch(list, etag: etag, lastModified: lastModified)))
                    } catch {
                        return (list, .failure(error))
                    }
                }
            }
            var collected: [(FilterList, Result<FilterDownloader.Outcome, any Error>)] = []
            for await item in group {
                collected.append(item)
                progress?(.downloading(completed: collected.count, total: total))
            }
            return collected
        }

        let now = Date()
        for (list, result) in results {
            var record = state[filter: list.id]
            switch result {
            case .success(.notModified):
                record.checkedAt = now
                record.lastError = nil
            case .success(.downloaded(let data, let etag, let lastModified)):
                do {
                    try store.writeFilter(id: list.id, data: data)
                    let hash = Self.sha256(data)
                    if hash != record.contentHash {
                        record.contentHash = hash
                        record.downloadedAt = now
                        summary.changedFilterIDs.append(list.id)
                    }
                    let text = String(decoding: data, as: UTF8.self)
                    let metadata = RuleText.metadata(of: text)
                    record.title = metadata.title
                    record.version = metadata.version
                    record.ruleCount = RuleText.lines(of: text).count
                    record.byteCount = data.count
                    record.etag = etag
                    record.lastModified = lastModified
                    record.checkedAt = now
                    record.lastError = nil
                } catch {
                    record.lastError = Self.describe(error)
                }
            case .failure(let error):
                if Task.isCancelled {
                    // iOS ended the background task: not a list problem, keep
                    // the previous record and stop the update. (A "cancelled"
                    // error without a cancelled task is an ordinary failure.)
                    summary.wasCancelled = true
                    continue
                }
                record.lastError = Self.describe(error)
            }
            if let error = record.lastError {
                summary.failedFilters[list.id] = error
                logger.error("Download of list \(list.id) failed: \(error, privacy: .public)")
            }
            state[filter: list.id] = record
        }
    }

    private func build(
        _ kind: BlockerKind,
        settings: ScudoSettings,
        state: inout PersistedState,
        forceConversion: Bool,
        summary: inout UpdateSummary,
        progress: (@Sendable (EngineProgress) -> Void)?
    ) {
        var record = state[blocker: kind]
        defer { state[blocker: kind] = record }
        let lists = settings.enabledLists(for: kind)
        let available = lists.filter { store.hasFilter(id: $0.id) }
        // Kept current even when nothing has to be rebuilt (e.g. a newly
        // enabled list that failed to download, or a missing list switched off).
        record.missingFilterIDs = lists.filter { !store.hasFilter(id: $0.id) }.map(\.id)
        let customRules = settings.customRuleLines(for: kind)

        let baseFingerprint = Self.fingerprint([
            "base-v1", kind.rawValue,
            "safari=\(RuleConverter.safariVersion)",
            "converter=\(RuleConverter.converterVersion)",
            "max=\(RuleConverter.maxJSONBytes)",
            "lists=" + available.map { "\($0.id):\(state[filter: $0.id].contentHash ?? "-")" }.joined(separator: ","),
            "custom=" + customRules.joined(separator: "\n"),
        ])
        let fingerprint = Self.fingerprint([baseFingerprint, "allow=" + settings.allowlist.joined(separator: ",")])

        let upToDate = record.fingerprint == fingerprint && record.buildError == nil && store.hasRules(for: kind)
        if upToDate && !forceConversion { return }

        progress?(.converting(kind))
        do {
            // Step 1: the slow conversion, only when the lists or custom rules changed.
            let base: ConversionOutput
            if !forceConversion, record.baseFingerprint == baseFingerprint, let cached = store.baseRules(for: kind) {
                base = ConversionOutput(
                    json: cached,
                    safariRuleCount: record.baseSafariRuleCount,
                    sourceRuleCount: record.sourceRuleCount,
                    discardedRuleCount: record.baseDiscardedRuleCount,
                    unconvertibleRuleCount: record.unconvertibleRuleCount
                )
            } else {
                var rules: [String] = []
                for list in available {
                    if let text = store.filterText(id: list.id) {
                        rules += RuleText.lines(of: text)
                    }
                }
                rules += customRules
                let started = Date()
                base = RuleConverter.convert(rules: rules)
                logger.info("Converted \(kind.rawValue): \(rules.count) rules → \(base.safariRuleCount) in \(Date().timeIntervalSince(started))s")
                try store.writeBaseRules(base.json, for: kind)
                record.baseFingerprint = baseFingerprint
                record.convertedAt = Date()
                record.baseSafariRuleCount = base.safariRuleCount
                record.sourceRuleCount = base.sourceRuleCount
                record.baseDiscardedRuleCount = base.discardedRuleCount
                record.unconvertibleRuleCount = base.unconvertibleRuleCount
                record.includedFilterIDs = available.map(\.id)
            }

            // Step 2: append the allowlist (instant) and publish for the extension.
            let final = RuleConverter.finalize(base: base, allowlistDomains: settings.allowlist)
            try store.writeRules(final.json, for: kind)
            record.fingerprint = fingerprint
            record.builtAt = Date()
            record.safariRuleCount = final.safariRuleCount
            record.discardedRuleCount = final.discardedRuleCount
            record.jsonByteCount = final.json.utf8.count
            record.buildError = nil
            summary.rebuiltBlockers.append(kind)
        } catch {
            record.buildError = Self.describe(error)
            summary.blockerErrors[kind] = record.buildError
            logger.error("Building \(kind.rawValue) failed: \(record.buildError ?? "", privacy: .public)")
        }
    }

    private func pendingKinds(in state: PersistedState) -> [BlockerKind] {
        BlockerKind.allCases.filter { state[blocker: $0].needsReload }
    }

    private func reload(
        _ kinds: [BlockerKind],
        state: inout PersistedState,
        summary: inout UpdateSummary,
        progress: (@Sendable (EngineProgress) -> Void)?
    ) async {
        guard let reloader else { return }
        for kind in kinds {
            var record = state[blocker: kind]
            if Task.isCancelled {
                summary.wasCancelled = true
                return
            }
            progress?(.reloading(kind))
            do {
                switch try await reloader(kind) {
                case .reloaded:
                    record.reloadedFingerprint = record.fingerprint
                    record.reloadedAt = Date()
                    record.reloadError = nil
                case .extensionDisabled:
                    // Nothing to retry: the app reloads an extension as soon as
                    // it sees the user switch it on (see AppModel.becameActive).
                    record.reloadedFingerprint = record.fingerprint
                    record.reloadError = nil
                }
            } catch {
                record.reloadError = Self.describe(error)
                summary.blockerErrors[kind] = record.reloadError
                logger.error("Reloading \(kind.rawValue) failed: \(record.reloadError ?? "", privacy: .public)")
            }
            state[blocker: kind] = record
        }
    }

    // MARK: Helpers

    private func persist(_ state: PersistedState) {
        do {
            try store.save(state)
        } catch {
            logger.error("Saving state failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func fingerprint(_ parts: [String]) -> String {
        sha256(Data(parts.joined(separator: "\u{1F}").utf8))
    }

    static func describe(_ error: any Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
