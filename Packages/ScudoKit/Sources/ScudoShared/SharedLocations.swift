import Foundation

/// Where the app and the content blocker extensions exchange data.
///
/// Layout inside the App Group container:
///
///     Scudo/
///       settings.json        user choices (lists, allowlist, custom rules)
///       state.json           download / conversion bookkeeping
///       Filters/<id>.txt     raw filter lists as downloaded
///       Blockers/<kind>.json Safari rules handed to each extension
public enum SharedLocations {
    public static let rootFolderName = "Scudo"
    public static let blockersFolderName = "Blockers"
    public static let filtersFolderName = "Filters"
    public static let settingsFileName = "settings.json"
    public static let stateFileName = "state.json"

    /// Info.plist key holding the App Group identifier. Its value comes from
    /// the `APP_GROUP_ID` build setting, so it is defined in a single place.
    public static let appGroupInfoKey = "ScudoAppGroup"

    /// Info.plist key of each content blocker extension naming the
    /// ``BlockerKind`` it serves.
    public static let blockerKindInfoKey = "ScudoBlockerKind"

    /// Name (without extension) of the fallback rules bundled in every
    /// content blocker extension.
    public static let bundledFallbackName = "blockerList"

    public static func appGroupIdentifier(in bundle: Bundle) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: appGroupInfoKey) as? String,
              !value.isEmpty, !value.contains("$(")
        else { return nil }
        return value
    }

    public static func rootDirectory(appGroup: String) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: rootFolderName, directoryHint: .isDirectory)
    }

    public static func rulesFile(for kind: BlockerKind, root: URL) -> URL {
        root.appending(path: blockersFolderName, directoryHint: .isDirectory)
            .appending(path: kind.rulesFileName, directoryHint: .notDirectory)
    }
}

/// Safari requires every content blocker to contain at least one rule. This
/// one never matches anything and is used whenever a blocker has no rules.
public enum PlaceholderRules {
    public static let json =
        #"[{"trigger":{"url-filter":".*","if-domain":["scudo-placeholder.invalid"]},"action":{"type":"ignore-previous-rules"}}]"#
}

/// Used by the content blocker extensions to find the rules for Safari.
public enum BlockerListLocator {
    /// The rules file produced by the app, or the bundled fallback when the
    /// app has not produced one yet (e.g. the extension was enabled before
    /// the app was ever opened).
    public static func rulesURL(bundle: Bundle) -> URL? {
        if let group = SharedLocations.appGroupIdentifier(in: bundle),
           let rawKind = bundle.object(forInfoDictionaryKey: SharedLocations.blockerKindInfoKey) as? String,
           let kind = BlockerKind(rawValue: rawKind),
           let root = SharedLocations.rootDirectory(appGroup: group) {
            let url = SharedLocations.rulesFile(for: kind, root: root)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                return url
            }
        }
        return bundle.url(forResource: SharedLocations.bundledFallbackName, withExtension: "json")
    }
}
