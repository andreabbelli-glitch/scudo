import Foundation
import Observation
import ScudoKit
import ScudoShared

struct UserMessage: Identifiable {
    let id = UUID()
    let title: String
    let body: String
}

/// State of the app for the SwiftUI views.
@MainActor
@Observable
final class AppModel {
    private(set) var settings: ScudoSettings = .defaults
    private(set) var state = PersistedState()
    /// Whether each extension is switched on in Safari (missing = unknown).
    private(set) var extensionStates: [BlockerKind: Bool] = [:]
    private(set) var isWorking = false
    private(set) var progress: EngineProgress?
    /// Filter lists were switched on/off and not applied yet.
    private(set) var hasPendingListChanges = false
    var message: UserMessage?
    let setupError: String?

    @ObservationIgnored private let engine: ProtectionEngine?
    @ObservationIgnored private var didLaunch = false
    @ObservationIgnored private var isMaintaining = false
    @ObservationIgnored private var runningOperations = 0
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init() {
        switch AppServices.engine {
        case .success(let engine):
            self.engine = engine
            self.setupError = nil
            settings = engine.store.loadSettings()
            state = engine.store.loadState()
        case .failure(let error):
            self.engine = nil
            self.setupError = error.localizedDescription
        }
    }

    // MARK: Derived values

    func record(for kind: BlockerKind) -> BlockerRecord {
        state[blocker: kind]
    }

    func record(for list: FilterList) -> FilterRecord {
        state[filter: list.id]
    }

    func isEnabled(_ list: FilterList) -> Bool {
        settings.isEnabled(list)
    }

    var totalRuleCount: Int {
        BlockerKind.allCases.reduce(0) { $0 + state[blocker: $1].safariRuleCount }
    }

    var enabledListCount: Int {
        FilterCatalog.all.filter(settings.isEnabled).count
    }

    var enabledExtensionCount: Int {
        BlockerKind.allCases.filter { extensionStates[$0] == true }.count
    }

    var allExtensionsEnabled: Bool {
        enabledExtensionCount == BlockerKind.allCases.count
    }

    var hasProblems: Bool {
        BlockerKind.allCases.contains { kind in
            let record = state[blocker: kind]
            return record.buildError != nil || record.reloadError != nil
        }
    }

    /// Enabled lists whose last download failed (the cached copy, if any, is still used).
    var failedListCount: Int {
        FilterCatalog.all.filter { settings.isEnabled($0) && state[filter: $0.id].lastError != nil }.count
    }

    /// True when the lists should be refreshed without waiting for the user:
    /// first launch, lists never downloaded (e.g. first launch offline), or
    /// last check older than the background interval.
    private var needsAutomaticUpdate: Bool {
        guard let engine else { return false }
        let missingRules = BlockerKind.allCases.contains { !engine.store.hasRules(for: $0) }
        let missingLists = BlockerKind.allCases.contains { !state[blocker: $0].missingFilterIDs.isEmpty }
        guard let lastUpdate = state.lastUpdateAt else { return true }
        let stale = Date().timeIntervalSince(lastUpdate) > BackgroundRefresh.interval
        return missingRules || missingLists || (settings.automaticUpdates && stale)
    }

    var progressDescription: String {
        switch progress {
        case .downloading(let completed, let total): "Scarico le liste… \(completed)/\(total)"
        case .converting(let kind): "Preparo le regole: \(kind.title)…"
        case .reloading(let kind): "Carico in Safari: \(kind.title)…"
        case nil: "Un momento…"
        }
    }

    // MARK: Lifecycle

    func onLaunch() async {
        guard !didLaunch, engine != nil else { return }
        didLaunch = true
        await refreshExtensionStates()
        await automaticMaintenance()
        if settings.automaticUpdates {
            BackgroundRefresh.schedule()
        }
    }

    /// The app came back to the foreground: the user may have switched
    /// extensions on in Settings, or a background refresh may have run.
    func becameActive() async {
        guard didLaunch, let engine, !isWorking, !isMaintaining else { return }
        state = engine.store.loadState()
        let previous = extensionStates
        await refreshExtensionStates()
        // Extensions the user just switched on in Settings: make sure Safari
        // loads the current rules rather than an older compiled copy.
        let switchedOn = BlockerKind.allCases.filter { previous[$0] == false && extensionStates[$0] == true }
        if !switchedOn.isEmpty {
            await perform(reportErrors: false) { engine, progress in
                await engine.reload(switchedOn, progress: progress)
            }
        }
        await automaticMaintenance()
    }

    /// Updates the lists when needed, otherwise makes sure Safari loaded the
    /// latest rules. Errors are shown in the lists, not in an alert.
    private func automaticMaintenance() async {
        // Launch and the first "active" scene phase can both get here.
        guard !isMaintaining else { return }
        isMaintaining = true
        defer { isMaintaining = false }
        if needsAutomaticUpdate {
            await saveTask?.value
            await perform(reportErrors: false) { engine, progress in
                await engine.update(progress: progress)
            }
        } else {
            await reloadPending()
        }
    }

    func refreshExtensionStates() async {
        var states: [BlockerKind: Bool] = [:]
        for kind in BlockerKind.allCases {
            if let enabled = await SafariBridge.isEnabled(kind) {
                states[kind] = enabled
            }
        }
        extensionStates = states
    }

    // MARK: Updates

    /// Checks the lists for updates and rebuilds what changed (user request:
    /// problems are reported in an alert).
    func update(force: Bool = false) async {
        await saveTask?.value
        await perform { engine, progress in
            await engine.update(forceDownload: force, forceRebuild: force, progress: progress)
        }
    }

    func applyPendingListChanges() async {
        guard hasPendingListChanges else { return }
        hasPendingListChanges = false
        await update()
    }

    private func reloadPending() async {
        guard BlockerKind.allCases.contains(where: { state[blocker: $0].needsReload }) else { return }
        await perform(reportErrors: false) { engine, progress in
            await engine.reloadPending(progress: progress)
        }
    }

    /// Rebuilds from the lists already downloaded (allowlist and custom rules).
    private func applyLocalChange() async {
        await saveTask?.value
        await perform { engine, progress in
            await engine.update(skipDownload: true, progress: progress)
        }
    }

    private func perform(
        reportErrors: Bool = true,
        _ operation: (ProtectionEngine, @escaping @Sendable (EngineProgress) -> Void) async -> UpdateSummary
    ) async {
        guard let engine else { return }
        runningOperations += 1
        isWorking = true
        let summary = await operation(engine) { [weak self] value in
            Task { @MainActor in
                guard let self, self.isWorking else { return }
                self.progress = value
            }
        }
        runningOperations -= 1
        if runningOperations == 0 {
            isWorking = false
            progress = nil
        }
        state = await engine.state()
        await refreshExtensionStates()
        if reportErrors, summary.hasErrors {
            message = Self.message(for: summary)
        }
    }

    private static func message(for summary: UpdateSummary) -> UserMessage {
        var lines: [String] = []
        for (id, error) in summary.failedFilters.sorted(by: { $0.key < $1.key }) {
            lines.append("• \(FilterCatalog.list(id: id)?.name ?? "Lista \(id)"): \(error)")
        }
        for kind in BlockerKind.allCases {
            if let error = summary.blockerErrors[kind] {
                lines.append("• \(kind.extensionDisplayName): \(error)")
            }
        }
        return UserMessage(
            title: "Aggiornamento incompleto",
            body: lines.joined(separator: "\n") + "\n\nLe regole già installate restano attive."
        )
    }

    // MARK: Settings

    func setList(_ list: FilterList, enabled: Bool) {
        if enabled {
            settings.enabledFilterIDs.insert(list.id)
        } else {
            settings.enabledFilterIDs.remove(list.id)
        }
        hasPendingListChanges = true
        persistSettings()
    }

    func restoreDefaultLists() {
        settings.enabledFilterIDs = FilterCatalog.defaultEnabledIDs
        hasPendingListChanges = true
        persistSettings()
    }

    /// Returns an error message, or nil when the site was added.
    func addToAllowlist(_ input: String) async -> String? {
        guard let domain = DomainInput.normalize(input) else {
            return "Indirizzo non valido. Scrivi per esempio: esempio.it"
        }
        guard !settings.allowlist.contains(domain) else {
            return "\(domain) è già tra i siti consentiti."
        }
        settings.allowlist.append(domain)
        settings.allowlist.sort()
        persistSettings()
        await applyLocalChange()
        return nil
    }

    func removeFromAllowlist(_ domains: [String]) async {
        settings.allowlist.removeAll { domains.contains($0) }
        persistSettings()
        await applyLocalChange()
    }

    func saveCustomRules(_ text: String) async {
        guard text != settings.customRules else { return }
        settings.customRules = text
        persistSettings()
        await applyLocalChange()
    }

    func setAutomaticUpdates(_ enabled: Bool) {
        settings.automaticUpdates = enabled
        persistSettings()
        if enabled {
            BackgroundRefresh.schedule()
        } else {
            BackgroundRefresh.cancel()
        }
    }

    /// Saves are chained so that they reach the disk in order.
    private func persistSettings() {
        guard let engine else { return }
        let snapshot = settings
        let previous = saveTask
        saveTask = Task {
            await previous?.value
            do {
                try await engine.save(snapshot)
            } catch {
                await MainActor.run {
                    self.message = UserMessage(title: "Impossibile salvare", body: error.localizedDescription)
                }
            }
        }
    }
}
