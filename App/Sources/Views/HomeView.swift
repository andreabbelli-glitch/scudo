import ScudoKit
import ScudoShared
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                if let error = model.setupError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } header: {
                        Text("Configurazione")
                    }
                }

                Section {
                    StatusHeader()
                    if !model.allExtensionsEnabled {
                        OpenSettingsButton()
                    }
                }

                Section {
                    ForEach(BlockerKind.allCases) { kind in
                        BlockerRow(kind: kind)
                    }
                } header: {
                    Text("Estensioni di Safari")
                } footer: {
                    if !model.allExtensionsEnabled {
                        Text("Attivale in Impostazioni › App › Safari › Estensioni: ognuna blocca una categoria diversa.")
                    }
                }

                Section("Filtri") {
                    UpdateRow()
                    NavigationLink {
                        FilterListsView()
                    } label: {
                        LabeledContent {
                            Text("\(model.enabledListCount) attive")
                        } label: {
                            Label("Liste di filtri", systemImage: "list.bullet.rectangle")
                        }
                    }
                }

                Section("Personalizza") {
                    NavigationLink {
                        AllowlistView()
                    } label: {
                        LabeledContent {
                            Text("\(model.settings.allowlist.count)")
                        } label: {
                            Label("Siti consentiti", systemImage: "checkmark.seal")
                        }
                    }
                    NavigationLink {
                        CustomRulesView()
                    } label: {
                        Label("Regole personali", systemImage: "square.and.pencil")
                    }
                    Toggle(isOn: Binding(
                        get: { model.settings.automaticUpdates },
                        set: { model.setAutomaticUpdates($0) }
                    )) {
                        Label("Aggiornamento automatico", systemImage: "arrow.triangle.2.circlepath")
                    }
                }

                Section {
                    NavigationLink {
                        GuideView()
                    } label: {
                        Label("Come si usa", systemImage: "questionmark.circle")
                    }
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("Informazioni", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("Scudo")
            .refreshable {
                await model.update()
            }
        }
        .task {
            await model.onLaunch()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await model.becameActive() }
            case .background:
                if model.settings.automaticUpdates {
                    BackgroundRefresh.schedule()
                }
            default:
                break
            }
        }
        .alert(
            model.message?.title ?? "",
            isPresented: Binding(
                get: { model.message != nil },
                set: { if !$0 { model.message = nil } }
            ),
            presenting: model.message
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message.body)
        }
    }
}

/// Big status line at the top of the home screen.
struct StatusHeader: View {
    @Environment(AppModel.self) private var model

    private enum Status {
        case unavailable, preparing, off, partial(Int), warning, active
    }

    private var status: Status {
        if model.setupError != nil { return .unavailable }
        if model.totalRuleCount == 0 && model.isWorking { return .preparing }
        if model.enabledExtensionCount == 0 { return .off }
        if !model.allExtensionsEnabled { return .partial(model.enabledExtensionCount) }
        if model.hasProblems { return .warning }
        return .active
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 44))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
                .frame(width: 56)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch status {
        case .unavailable: "exclamationmark.shield.fill"
        case .preparing: "shield.lefthalf.filled"
        case .off: "shield.slash.fill"
        case .partial: "shield.lefthalf.filled"
        case .warning: "exclamationmark.shield.fill"
        case .active: "checkmark.shield.fill"
        }
    }

    private var color: Color {
        switch status {
        case .unavailable: .red
        case .preparing: .secondary
        case .off, .partial, .warning: .orange
        case .active: .green
        }
    }

    private var title: String {
        switch status {
        case .unavailable: "Configurazione incompleta"
        case .preparing: "Preparazione in corso"
        case .off: "Protezione non attiva"
        case .partial: "Protezione parziale"
        case .warning: "Attiva, con avvisi"
        case .active: "Protezione attiva"
        }
    }

    private var subtitle: String {
        let rules = model.totalRuleCount.formatted()
        switch status {
        case .unavailable: return "Controlla la capability App Groups del progetto."
        case .preparing: return model.progressDescription
        case .off: return "Attiva le estensioni in Safari per iniziare a bloccare."
        case .partial(let count): return "\(count) estensioni su \(BlockerKind.allCases.count) attive in Safari."
        case .warning: return "Alcune regole non sono state caricate: vedi sotto."
        case .active: return "\(rules) regole in funzione in Safari."
        }
    }
}

struct BlockerRow: View {
    @Environment(AppModel.self) private var model
    let kind: BlockerKind

    var body: some View {
        let record = model.record(for: kind)
        let error = record.buildError ?? record.reloadError
        HStack(spacing: 12) {
            Image(systemName: kind.systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.extensionDisplayName)
                Text(error ?? detail(record))
                    .font(.caption)
                    .foregroundStyle(error == nil ? Color.secondary : Color.red)
            }
            Spacer(minLength: 8)
            ExtensionBadge(enabled: model.extensionStates[kind])
        }
    }

    private func detail(_ record: BlockerRecord) -> String {
        if record.safariRuleCount == 0 {
            return model.isWorking ? "In preparazione…" : kind.summary
        }
        var text = "\(record.safariRuleCount.formatted()) regole"
        if record.discardedRuleCount > 0 {
            text += " · \(record.discardedRuleCount.formatted()) escluse per i limiti di Safari"
        }
        return text
    }
}

struct ExtensionBadge: View {
    let enabled: Bool?

    var body: some View {
        switch enabled {
        case true?:
            Label("Attiva", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        case false?:
            Label("Spenta", systemImage: "exclamationmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        case nil:
            EmptyView()
        }
    }
}

struct UpdateRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isWorking {
            HStack(spacing: 12) {
                ProgressView()
                Text(model.progressDescription)
                    .foregroundStyle(.secondary)
            }
        } else {
            Button {
                Task { await model.update() }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Aggiorna ora", systemImage: "arrow.clockwise")
                    if let date = model.state.lastUpdateAt {
                        Text("Ultimo controllo \(date.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if model.failedListCount > 0 {
                        Text("⚠︎ \(model.failedListCount) liste non aggiornate: dettagli in «Liste di filtri».")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .contextMenu {
                Button {
                    Task { await model.update(force: true) }
                } label: {
                    Label("Riscarica e ricostruisci tutto", systemImage: "arrow.counterclockwise")
                }
            }
        }
    }
}
