import ScudoKit
import ScudoShared
import SwiftUI

struct GuideView: View {
    var body: some View {
        List {
            Section("Attivazione") {
                GuideStep(number: 1, text: "Apri **Impostazioni › App › Safari › Estensioni**.")
                GuideStep(number: 2, text: "Attiva **Scudo Pubblicità**, **Scudo Privacy**, **Scudo Fastidi** e **Scudo Sicurezza**.")
                GuideStep(number: 3, text: "Torna in Scudo: lo stato in alto diventa verde.")
                OpenSettingsButton()
            }

            Section("Se un sito non funziona bene") {
                Text("In Safari apri il menu della pagina, scegli **Impostazioni sito web** e disattiva **Usa blocco contenuti**: vale solo per quel sito. In alternativa aggiungilo ai **Siti consentiti** di Scudo.")
            }

            Section("Aggiornamenti") {
                Text("Le liste si aggiornano da sole in background (quando iOS lo consente, di solito di notte) e quando apri l'app se sono passate più di 12 ore. Puoi anche tirare giù la schermata principale.")
            }

            Section("Limiti") {
                Text("I blocchi di contenuti di Safari non eseguono script: alcune pubblicità integrate nella pagina, come quelle dei video di YouTube, possono passare. Il blocco vale in Safari e nelle app che aprono pagine web con Safari, non dentro le altre app.")
            }
        }
        .navigationTitle("Come si usa")
        .inlineNavigationTitle()
    }
}

private struct GuideStep: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(.tint))
            Text(text)
        }
    }
}

struct AboutView: View {
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Versione", value: appVersion)
                LabeledContent("Regole generate per", value: "Safari \(RuleConverter.safariVersion)")
                LabeledContent("Convertitore", value: "SafariConverterLib \(RuleConverter.converterVersion)")
            }

            Section("Privacy") {
                Text("Scudo non raccoglie dati e non ha un server: scarica soltanto le liste di filtri da filters.adtidy.org. Il blocco avviene dentro Safari, che non comunica all'app quali siti visiti.")
            }

            Section("Crediti") {
                Text("Conversione delle regole: AdGuard SafariConverterLib (GPL-3.0).")
                Text("Liste di filtri: AdGuard, EasyList, EasyList Italy, Phishing URL Blocklist e gli altri autori indicati nelle liste, con le rispettive licenze.")
            }
        }
        .navigationTitle("Informazioni")
        .inlineNavigationTitle()
    }
}
