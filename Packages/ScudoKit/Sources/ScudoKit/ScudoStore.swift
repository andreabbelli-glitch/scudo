import Foundation
import ScudoShared

/// Errors surfaced to the user (messages in Italian).
public enum ScudoError: LocalizedError, Equatable {
    case appGroupUnavailable(String?)
    case httpStatus(Int)
    case notAFilterList
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable(let group):
            if let group {
                return "Impossibile accedere all'App Group \"\(group)\". Controlla che la capability App Groups sia attiva su app ed estensioni."
            }
            return "App Group non configurato (chiave ScudoAppGroup mancante in Info.plist)."
        case .httpStatus(let code):
            return "Il server ha risposto con errore HTTP \(code)."
        case .notAFilterList:
            return "Il file scaricato non sembra una lista di filtri."
        case .invalidResponse:
            return "Risposta del server non valida."
        }
    }
}

/// Reads and writes Scudo's files in the shared container.
public struct ScudoStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Store in the App Group container declared in the Info.plist of `bundle`.
    public static func shared(bundle: Bundle = .main) throws -> ScudoStore {
        guard let group = SharedLocations.appGroupIdentifier(in: bundle) else {
            throw ScudoError.appGroupUnavailable(nil)
        }
        guard let root = SharedLocations.rootDirectory(appGroup: group) else {
            throw ScudoError.appGroupUnavailable(group)
        }
        return ScudoStore(root: root)
    }

    // MARK: Locations

    public var settingsURL: URL { root.appending(path: SharedLocations.settingsFileName) }
    public var stateURL: URL { root.appending(path: SharedLocations.stateFileName) }
    public var filtersDirectory: URL { root.appending(path: SharedLocations.filtersFolderName, directoryHint: .isDirectory) }
    public var blockersDirectory: URL { root.appending(path: SharedLocations.blockersFolderName, directoryHint: .isDirectory) }
    /// Converted rules without the allowlist (see ``RuleConverter``).
    public var cacheDirectory: URL { root.appending(path: "Cache", directoryHint: .isDirectory) }

    public func filterURL(id: Int) -> URL {
        filtersDirectory.appending(path: "\(id).txt")
    }

    public func rulesURL(for kind: BlockerKind) -> URL {
        SharedLocations.rulesFile(for: kind, root: root)
    }

    public func baseRulesURL(for kind: BlockerKind) -> URL {
        cacheDirectory.appending(path: "\(kind.rawValue).base.json")
    }

    public func prepareDirectories() throws {
        for directory in [root, filtersDirectory, blockersDirectory, cacheDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    // MARK: Settings and state

    public func loadSettings() -> ScudoSettings {
        read(ScudoSettings.self, from: settingsURL) ?? .defaults
    }

    public func save(_ settings: ScudoSettings) throws {
        try write(settings, to: settingsURL)
    }

    public func loadState() -> PersistedState {
        read(PersistedState.self, from: stateURL) ?? PersistedState()
    }

    public func save(_ state: PersistedState) throws {
        try write(state, to: stateURL)
    }

    // MARK: Filter lists and rules

    public func filterText(id: Int) -> String? {
        guard let data = try? Data(contentsOf: filterURL(id: id)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func hasFilter(id: Int) -> Bool {
        FileManager.default.fileExists(atPath: filterURL(id: id).path(percentEncoded: false))
    }

    public func writeFilter(id: Int, data: Data) throws {
        try prepareDirectories()
        try data.write(to: filterURL(id: id), options: .atomic)
    }

    public func hasRules(for kind: BlockerKind) -> Bool {
        FileManager.default.fileExists(atPath: rulesURL(for: kind).path(percentEncoded: false))
    }

    /// Atomic write: the extension never sees a half-written file.
    public func writeRules(_ json: String, for kind: BlockerKind) throws {
        try prepareDirectories()
        try Data(json.utf8).write(to: rulesURL(for: kind), options: .atomic)
    }

    public func baseRules(for kind: BlockerKind) -> String? {
        guard let data = try? Data(contentsOf: baseRulesURL(for: kind)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func writeBaseRules(_ json: String, for kind: BlockerKind) throws {
        try prepareDirectories()
        try Data(json.utf8).write(to: baseRulesURL(for: kind), options: .atomic)
    }

    // MARK: JSON helpers

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try prepareDirectories()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
