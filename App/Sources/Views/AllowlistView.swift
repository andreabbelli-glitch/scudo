import ScudoKit
import SwiftUI

struct AllowlistView: View {
    @Environment(AppModel.self) private var model
    @State private var input = ""
    @State private var error: String?

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("esempio.it", text: $input)
                        .domainInput()
                        .onSubmit(add)
                    Button("Aggiungi", action: add)
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || model.isWorking)
                }
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("Su questi siti, e sui loro sottodomini, Scudo non blocca nulla. Puoi incollare anche un indirizzo completo.")
            }

            Section {
                if model.settings.allowlist.isEmpty {
                    Text("Nessun sito consentito")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.settings.allowlist, id: \.self) { domain in
                        Text(domain)
                    }
                    .onDelete { offsets in
                        let domains = offsets.map { model.settings.allowlist[$0] }
                        Task { await model.removeFromAllowlist(domains) }
                    }
                    .deleteDisabled(model.isWorking)
                }
            } header: {
                Text("Siti consentiti")
            } footer: {
                Text("Scorri a sinistra su un sito per rimuoverlo. Per una prova al volo, in Safari puoi anche disattivare il blocco solo per il sito aperto: menu della pagina › Impostazioni sito web › Usa blocco contenuti.")
            }
        }
        .navigationTitle("Siti consentiti")
        .inlineNavigationTitle()
        .safeAreaInset(edge: .bottom) {
            if model.isWorking {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(model.progressDescription)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding()
                .background(.bar)
            }
        }
    }

    private func add() {
        let text = input
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task {
            if let message = await model.addToAllowlist(text) {
                error = message
            } else {
                error = nil
                input = ""
            }
        }
    }
}
