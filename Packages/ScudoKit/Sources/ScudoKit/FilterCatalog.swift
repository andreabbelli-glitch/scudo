import Foundation
import ScudoShared

/// A filter list the app can download and convert.
public struct FilterList: Identifiable, Hashable, Sendable {
    /// AdGuard filter registry identifier (stable across updates).
    public let id: Int
    public let name: String
    public let summary: String
    public let blocker: BlockerKind
    public let enabledByDefault: Bool
    public let url: URL

    public init(id: Int, name: String, summary: String, blocker: BlockerKind, enabledByDefault: Bool, url: URL) {
        self.id = id
        self.name = name
        self.summary = summary
        self.blocker = blocker
        self.enabledByDefault = enabledByDefault
        self.url = url
    }
}

/// The lists offered in the app.
///
/// All lists are downloaded in the "iOS optimized" flavour published by the
/// AdGuard filter registry (https://filters.adtidy.org/ios/filters.json):
/// they are already translated to the syntax understood by the converter and
/// stripped of rules that Safari cannot apply, which keeps every content
/// blocker small. The registry also mirrors the EasyList family.
///
/// Defaults are chosen so that no blocker exceeds Safari's limits (150k rules,
/// ~19 MB, see ``RuleConverter/maxJSONBytes``). Measured in November 2026
/// (Safari rules / JSON): Base 40k / 6.1 MB, Tracking Protection 113k / 12 MB,
/// EasyPrivacy 37k / 3.9 MB, Phishing 71k / 9 MB, Malicious URL 47k / 9 MB.
/// When a blocker overflows, the converter drops its *last* rules, which are
/// the exceptions that keep sites working: better to stay below the limits.
public enum FilterCatalog {
    public static let all: [FilterList] = [
        // MARK: Pubblicità
        list(2, "AdGuard Base", "Il filtro principale: pubblicità di siti internazionali. Include EasyList.", .ads, on: true),
        list(11, "AdGuard Mobile Ads", "Annunci pensati per smartphone e tablet.", .ads, on: true),
        list(26, "AdGuard Italiano", "Pubblicità dei siti in lingua italiana.", .ads, on: true),
        list(109, "EasyList Italy", "Lista italiana della famiglia EasyList, complementare alla precedente.", .ads, on: true),
        list(101, "EasyList", "Alternativa ad AdGuard Base (che già la include): attivala solo se disattivi Base.", .ads, on: false),

        // MARK: Privacy
        list(3, "AdGuard Tracking Protection", "Contatori, statistiche e sistemi di tracciamento: la lista più completa.", .privacy, on: true),
        list(118, "EasyPrivacy", "In gran parte già coperta dalla precedente; insieme superano il limite di 150.000 regole di Safari.", .privacy, on: false),
        list(204, "Peter Lowe's Blocklist", "Server di pubblicità e tracciamento noti (lista di domini).", .privacy, on: false),

        // MARK: Fastidi
        list(18, "AdGuard Cookie Notices", "Nasconde i banner sul consenso ai cookie.", .annoyances, on: true),
        list(19, "AdGuard Popups", "Popup invadenti, richieste di notifiche, iscrizioni a newsletter.", .annoyances, on: true),
        list(20, "AdGuard Mobile App Banners", "Banner che invitano a installare l'app del sito.", .annoyances, on: true),
        list(21, "AdGuard Other Annoyances", "Altri elementi fastidiosi non coperti dalle liste precedenti.", .annoyances, on: true),
        list(22, "AdGuard Widgets", "Chat di assistenza e widget di terze parti.", .annoyances, on: false),
        list(241, "EasyList Cookie List", "Alternativa per i banner dei cookie (si sovrappone ad AdGuard Cookie Notices).", .annoyances, on: false),

        // MARK: Sicurezza
        list(255, "Phishing URL Blocklist", "Blocca siti di phishing noti (in aggiunta all'avviso siti fraudolenti di Safari).", .security, on: true),
        list(208, "Online Malicious URL Blocklist", "Siti che distribuiscono malware. Molto grande: insieme alla precedente sfiora il limite di Safari.", .security, on: false),
        list(4, "AdGuard Social Media", "Pulsanti \"mi piace\" e widget dei social network.", .security, on: false),
    ]

    public static func lists(for kind: BlockerKind) -> [FilterList] {
        all.filter { $0.blocker == kind }
    }

    public static func list(id: Int) -> FilterList? {
        all.first { $0.id == id }
    }

    public static var defaultEnabledIDs: Set<Int> {
        Set(all.filter(\.enabledByDefault).map(\.id))
    }

    private static func list(_ id: Int, _ name: String, _ summary: String, _ blocker: BlockerKind, on: Bool) -> FilterList {
        FilterList(
            id: id,
            name: name,
            summary: summary,
            blocker: blocker,
            enabledByDefault: on,
            url: URL(string: "https://filters.adtidy.org/ios/filters/\(id)_optimized.txt")!
        )
    }
}
