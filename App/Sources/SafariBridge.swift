import Foundation
import SafariServices
import ScudoKit
import ScudoShared

/// Talks to Safari about the content blocker extensions.
enum SafariBridge {
    static var appBundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? ""
    }

    static func identifier(for kind: BlockerKind) -> String {
        kind.extensionBundleIdentifier(appBundleIdentifier: appBundleIdentifier)
    }

    /// Asks Safari to load the latest rules of an extension.
    static func reload(_ kind: BlockerKind) async throws -> ReloadOutcome {
        do {
            try await SFContentBlockerManager.reloadContentBlocker(withIdentifier: identifier(for: kind))
            return .reloaded
        } catch {
            // A switched-off extension cannot be reloaded, which is fine:
            // Safari reads the latest file when the user switches it on.
            if await isEnabled(kind) == false {
                return .extensionDisabled
            }
            throw error
        }
    }

    /// Whether the user switched the extension on in Safari settings
    /// (`nil` when Safari cannot tell, e.g. the extension is not installed).
    static func isEnabled(_ kind: BlockerKind) async -> Bool? {
        do {
            return try await SFContentBlockerManager.stateOfContentBlocker(withIdentifier: identifier(for: kind)).isEnabled
        } catch {
            return nil
        }
    }

    /// Opens Safari › Extensions in Settings when the system allows it
    /// (iOS 26.2 and later). Returns false when it could not.
    @MainActor
    static func openExtensionSettings() async -> Bool {
        #if os(iOS)
        if #available(iOS 26.2, *) {
            do {
                try await SFSafariSettings.openExtensionsSettings(forIdentifiers: BlockerKind.allCases.map(identifier(for:)))
                return true
            } catch {
                return false
            }
        }
        #endif
        return false
    }
}
