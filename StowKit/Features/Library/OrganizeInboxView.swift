import SwiftUI

/// Batch organizing: suggestions for every Inbox document, each collection adjustable, then one
/// Apply that does for all of them what Use Suggestions does for one.
struct OrganizeInboxView: View {
    @Bindable var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    /// The owner's collection per document; absent means "use the suggestion".
    @State private var chosen: [UUID: String] = [:]
    @State private var excluded: Set<UUID> = []

    private var items: [InboxBatchItem] { library.organizeItems }
    private var working: Int { items.filter(\.working).count }
    private func collection(_ item: InboxBatchItem) -> String { chosen[item.id] ?? item.suggestion?.collection ?? "" }
    private var ready: [InboxBatchItem] { items.filter { !excluded.contains($0.id) && !$0.working && (!collection($0).isEmpty || $0.suggestion != nil) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Organize Inbox").font(.title2.weight(.semibold))
                    Text("Check each suggestion, change a collection if it's wrong, then apply. Nothing changes until you do.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Suggest for All") { library.suggestForAllInbox() }
                    .disabled(working > 0 || items.isEmpty)
                    .help("Ask Apple Intelligence (and your rules) again for every Inbox document")
            }
            if working > 0 {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading \(working) \(working == 1 ? "document" : "documents") for suggestions…").font(.caption).foregroundStyle(.secondary)
                }
            }
            Table(items) {
                TableColumn("") { item in
                    Toggle("", isOn: Binding(get: { !excluded.contains(item.id) },
                                             set: { if $0 { excluded.remove(item.id) } else { excluded.insert(item.id) } }))
                        .labelsHidden().toggleStyle(.checkbox).disabled(item.working)
                }.width(24)
                TableColumn("Document") { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.suggestion?.title.isEmpty == false ? item.suggestion!.title : item.title).lineLimit(1)
                        if let from = item.suggestion?.correspondent, !from.isEmpty {
                            Text(from).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        } else if item.suggestion?.title.isEmpty == false, item.suggestion?.title != item.title {
                            Text(item.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                TableColumn("Collection") { item in
                    if item.working {
                        HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Suggesting…").foregroundStyle(.secondary) }
                    } else {
                        Picker("", selection: Binding(get: { collection(item) }, set: { chosen[item.id] = $0 })) {
                            Text("None").tag("")
                            ForEach(library.collections) { Text($0.name).tag($0.name) }
                        }.labelsHidden()
                    }
                }.width(min: 130, ideal: 150)
                TableColumn("Suggestion") { item in
                    if let suggestion = item.suggestion {
                        Text(UnderstandingInspector.certainty(suggestion.confidence)).foregroundStyle(.secondary)
                    } else if !item.working {
                        Text("None yet").foregroundStyle(.tertiary)
                    }
                }.width(min: 110, ideal: 150)
            }
            .overlay { if items.isEmpty { ContentUnavailableView("Inbox Is Empty", systemImage: "tray") } }
            HStack {
                Text("Applying fills in each suggested title, sender, tags, and summary, files the document in the chosen collection, and marks it reviewed.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply to \(ready.count) \(ready.count == 1 ? "Document" : "Documents")") {
                    library.applyOrganize(Dictionary(uniqueKeysWithValues: ready.map { ($0.id, collection($0)) }))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(ready.isEmpty)
            }
        }
        .padding(20).frame(minWidth: 760, minHeight: 480)
        .onAppear { library.refreshOrganizeItems(); library.isOrganizingInbox = true }
        .onDisappear { library.isOrganizingInbox = false }
    }
}
