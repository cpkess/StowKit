import SwiftUI

/// The details pane when several documents are selected: one change applied to all of them.
struct BulkEditView: View {
    @Bindable var library: LibraryStore
    let ids: Set<UUID>
    @State private var tag = ""
    @State private var sender = ""
    @State private var type = ""
    @State private var date = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(ids.count) Documents Selected").font(.title2.weight(.semibold))
                    Text("Each change applies to all of them and counts as your edit, so suggestions won’t replace it.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                GroupBox("Collections") {
                    HStack {
                        Menu("Add to Collection") {
                            ForEach(library.collections) { collection in
                                Button(collection.name) { library.bulkEdit(ids) { $0.collections.insert(collection.name) } }
                            }
                        }
                        Menu("Remove from Collection") {
                            ForEach(library.collections) { collection in
                                Button(collection.name) { library.bulkEdit(ids) { $0.collections.remove(collection.name) } }
                            }
                        }
                        Spacer()
                    }.padding(4)
                }
                GroupBox("Tags") {
                    HStack {
                        TextField("Tag", text: $tag).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                        Button("Add") { let value = tag; library.bulkEdit(ids) { Self.add(value, to: &$0) } }.disabled(clean(tag).isEmpty)
                        Button("Remove") { let value = tag; library.bulkEdit(ids) { Self.remove(value, from: &$0) } }.disabled(clean(tag).isEmpty)
                        Spacer()
                    }.padding(4)
                }
                GroupBox("Details") {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            Text("From").foregroundStyle(.secondary)
                            TextField("Sender", text: $sender).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                            Button("Set") { let value = clean(sender); library.bulkEdit(ids) { $0.correspondent = value } }
                        }
                        GridRow {
                            Text("Type").foregroundStyle(.secondary)
                            TextField("Bill, policy, receipt…", text: $type).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                            Button("Set") { let value = clean(type); library.bulkEdit(ids) { $0.documentType = value } }
                        }
                        GridRow {
                            Text("Date").foregroundStyle(.secondary)
                            DatePicker("Date", selection: $date, displayedComponents: .date).labelsHidden()
                            Button("Set") { let value = date; library.bulkEdit(ids) { $0.documentDate = value } }
                        }
                    }.padding(4)
                }
                GroupBox("Status") {
                    HStack {
                        Button("Mark Reviewed") { library.bulkEdit(ids) { $0.needsReview = false } }
                        Button("Mark Needs Review") { library.bulkEdit(ids) { $0.needsReview = true } }
                        Button("Add to Favorites") { library.bulkEdit(ids) { $0.favorite = true } }
                        Button("Remove from Favorites") { library.bulkEdit(ids) { $0.favorite = false } }
                        Spacer()
                    }.padding(4)
                }
                HStack {
                    Button("Suggest Again") { library.suggestAgain(ids) }
                        .help("Ask Apple Intelligence and your rules again; fields you edited stay as they are")
                    Spacer()
                    Button("Move to Trash", role: .destructive) { library.bulkEdit(ids) { $0.trashedAt = Date() } }
                }
            }.padding(20)
        }
    }
    private func clean(_ value: String) -> String { value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: " ") }
    static func add(_ tag: String, to document: inout HouseholdDocument) {
        let value = tag.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: " ")
        guard !value.isEmpty, !document.tagList.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { return }
        document.tags = (document.tagList + [value]).joined(separator: ", ")
    }
    static func remove(_ tag: String, from document: inout HouseholdDocument) {
        let key = tag.trimmingCharacters(in: .whitespaces).lowercased()
        document.tags = document.tagList.filter { $0.lowercased() != key }.joined(separator: ", ")
    }
}
