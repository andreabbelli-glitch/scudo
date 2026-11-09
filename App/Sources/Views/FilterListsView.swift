import ScudoKit
import ScudoShared
import SwiftUI

struct FilterListsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            ForEach(BlockerKind.allCases) { kind in
                Section {
                    ForEach(FilterCatalog.lists(for: kind)) { list in
                        FilterListRow(list: list)
                    }
                } header: {
                    Label(kind.title, systemImage: kind.systemImage)
                } footer: {
                    BlockerFooter(kind: kind)
                }
            }

            Section {
                Button("Ripristina le liste predefinite") {
                    model.restoreDefaultLists()
                }
            } footer: {
                Text("Le liste sono mantenute da AdGuard e dalla comunità EasyList e vengono scaricate da filters.adtidy.org. Ogni categoria corrisponde a un'estensione di Safari con un limite di 150.000 regole.")
            }
        }
        .navigationTitle("Liste di filtri")
        .inlineNavigationTitle()
        .safeAreaInset(edge: .bottom) {
            if model.hasPendingListChanges || model.isWorking {
                ApplyBar()
            }
        }
        .onDisappear {
            Task { await model.applyPendingListChanges() }
        }
    }
}

private struct ApplyBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.isWorking {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(model.progressDescription)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                Button {
                    Task { await model.applyPendingListChanges() }
                } label: {
                    Text("Applica le modifiche")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding()
        .background(.bar)
    }
}

private struct FilterListRow: View {
    @Environment(AppModel.self) private var model
    let list: FilterList

    var body: some View {
        Toggle(isOn: Binding(
            get: { model.isEnabled(list) },
            set: { model.setList(list, enabled: $0) }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                Text(list.name)
                Text(list.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let status {
                    Text(status.text)
                        .font(.caption2)
                        .foregroundStyle(status.isError ? Color.red : Color.secondary)
                }
            }
        }
        .disabled(model.isWorking)
    }

    private var status: (text: String, isError: Bool)? {
        guard model.isEnabled(list) else { return nil }
        let record = model.record(for: list)
        if let error = record.lastError {
            return ("Errore: \(error)", true)
        }
        guard let count = record.ruleCount else {
            return model.hasPendingListChanges ? ("Verrà scaricata applicando le modifiche", false) : nil
        }
        var text = "\(count.formatted()) regole"
        if let date = record.downloadedAt {
            text += " · aggiornata \(date.formatted(.relative(presentation: .named)))"
        }
        return (text, false)
    }
}

private struct BlockerFooter: View {
    @Environment(AppModel.self) private var model
    let kind: BlockerKind

    var body: some View {
        let record = model.record(for: kind)
        VStack(alignment: .leading, spacing: 4) {
            if record.safariRuleCount > 0 {
                Text("«\(kind.extensionDisplayName)»: \(record.safariRuleCount.formatted()) regole per Safari (\(Int64(record.jsonByteCount).formatted(.byteCount(style: .file)))).")
            }
            if record.discardedRuleCount > 0 {
                Text("⚠︎ \(record.discardedRuleCount.formatted()) regole escluse per i limiti di Safari: disattiva qualche lista in questa categoria.")
                    .foregroundStyle(.orange)
            }
            if !record.missingFilterIDs.isEmpty {
                Text("⚠︎ Liste non ancora scaricate: \(record.missingFilterIDs.compactMap { FilterCatalog.list(id: $0)?.name }.joined(separator: ", ")).")
                    .foregroundStyle(.orange)
            }
            if kind == .security {
                Text("Qui finiscono anche le tue regole personali.")
            }
        }
    }
}
