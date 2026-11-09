import ScudoKit
import SwiftUI

struct CustomRulesView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var loaded = false
    @State private var check: (safariRuleCount: Int, unsupportedCount: Int)?

    private var lineCount: Int {
        RuleText.lines(of: text).count
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 220)
                    .codeInput()
            } header: {
                Text("Una regola per riga")
            } footer: {
                if let check, lineCount > 0 {
                    if check.unsupportedCount > 0 {
                        Text("\(lineCount) regole, \(check.unsupportedCount) non utilizzabili in Safari (sintassi errata o regole avanzate).")
                            .foregroundStyle(.orange)
                    } else {
                        Text("\(lineCount) regole valide.")
                    }
                }
            }

            Section("Esempi") {
                ExampleRule(rule: "||esempio.com^", meaning: "blocca tutto ciò che arriva da esempio.com")
                ExampleRule(rule: "esempio.it##.banner-alto", meaning: "nasconde l'elemento .banner-alto su esempio.it")
                ExampleRule(rule: "##.popup-newsletter", meaning: "nasconde .popup-newsletter su tutti i siti")
                ExampleRule(rule: "@@||cdn.esempio.com^", meaning: "eccezione: non bloccare mai cdn.esempio.com")
                ExampleRule(rule: "! commento", meaning: "le righe che iniziano con ! sono ignorate")
            }

            Section {
                Text("Sintassi AdBlock/AdGuard. Le regole di blocco finiscono nell'estensione «Scudo Sicurezza», che deve essere attiva; le eccezioni (@@ e #@#) valgono per tutte le estensioni. Scriptlet ed extended CSS non sono supportati dai blocchi di contenuti di Safari.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Regole personali")
        .inlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if model.isWorking {
                    ProgressView()
                } else {
                    Button("Salva") {
                        Task { await model.saveCustomRules(text) }
                    }
                    .disabled(text == model.settings.customRules)
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            text = model.settings.customRules
            loaded = true
        }
        .task(id: text) {
            // Small debounce, then validate the rules as the user types.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            check = RuleConverter.check(rules: RuleText.lines(of: text))
        }
    }
}

private struct ExampleRule: View {
    let rule: String
    let meaning: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(rule)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
            Text(meaning)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
