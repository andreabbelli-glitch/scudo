import Foundation

/// The Safari content blocker extensions shipped with the app.
///
/// Every kind is a separate extension (a separate switch in Safari settings)
/// with its own rules file: Safari compiles and limits each content blocker
/// independently, so splitting the lists keeps every blocker well below the
/// rule-count and memory limits.
public enum BlockerKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case ads
    case privacy
    case annoyances
    case security

    public var id: String { rawValue }

    /// Appended to the app bundle identifier to obtain the extension bundle
    /// identifier (e.g. `com.example.scudo.blocker.ads`). Must match the
    /// `PRODUCT_BUNDLE_IDENTIFIER` of the extension targets in `project.yml`.
    public var bundleIdentifierSuffix: String { "blocker.\(rawValue)" }

    public func extensionBundleIdentifier(appBundleIdentifier: String) -> String {
        "\(appBundleIdentifier).\(bundleIdentifierSuffix)"
    }

    /// Name of the Safari rules JSON inside the shared container.
    public var rulesFileName: String { "\(rawValue).json" }

    /// Short title used inside the app.
    public var title: String {
        switch self {
        case .ads: "Pubblicità"
        case .privacy: "Privacy"
        case .annoyances: "Fastidi"
        case .security: "Sicurezza e regole tue"
        }
    }

    /// Name shown in Settings › Apps › Safari › Extensions. Must match the
    /// `SCUDO_BLOCKER_DISPLAY_NAME` build setting of the extension target.
    public var extensionDisplayName: String {
        switch self {
        case .ads: "Scudo Pubblicità"
        case .privacy: "Scudo Privacy"
        case .annoyances: "Scudo Fastidi"
        case .security: "Scudo Sicurezza"
        }
    }

    public var summary: String {
        switch self {
        case .ads: "Banner, video e annunci, anche sui siti italiani."
        case .privacy: "Tracker, statistiche e pixel di profilazione."
        case .annoyances: "Banner dei cookie, popup, inviti a scaricare app."
        case .security: "Siti di phishing e malware, più le tue regole personali."
        }
    }

    /// SF Symbol for the kind.
    public var systemImage: String {
        switch self {
        case .ads: "rectangle.slash"
        case .privacy: "eye.slash"
        case .annoyances: "hand.raised"
        case .security: "lock.shield"
        }
    }
}
