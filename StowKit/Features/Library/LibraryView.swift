import SwiftUI

struct LibraryView: View {
    @Bindable var library: LibraryStore
    @FocusState private var searchFocused: Bool
    @State private var showImportInfo = false
    @State private var showCollectionSheet = false
    @State private var collectionName = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $library.destination) {
                Section {
                    Label("Inbox", systemImage: "tray")
                        .badge(library.documents.filter(\.needsReview).count)
                        .tag(LibraryDestination.inbox)
                    Label("Recent", systemImage: "clock").tag(LibraryDestination.recent)
                    Label("Favorites", systemImage: "star").tag(LibraryDestination.favorites)
                }
                Section("Collections") {
                    ForEach(library.collections) { collection in
                        Label(collection.name, systemImage: collection.symbol)
                            .tag(LibraryDestination.collection(collection.name))
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("StowKit")
            .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 260)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Label("Sample Library", systemImage: "externaldrive")
                    Spacer()
                    Button { showCollectionSheet = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("New Collection")
                        .accessibilityLabel("New Collection")
                }.font(.caption).foregroundStyle(.secondary).padding(14)
            }
        } content: {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search \(library.destination == .recent ? "documents" : (library.destination?.title.lowercased() ?? "documents"))", text: $library.search)
                        .textFieldStyle(.plain).focused($searchFocused)
                        .accessibilityLabel("Search documents")
                    if !library.search.isEmpty {
                        Button { library.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear Search")
                    }
                }.padding(9).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6)).padding(12)
                Divider()
                if library.visibleDocuments.isEmpty {
                    ContentUnavailableView {
                        Label(library.search.isEmpty ? "No Documents" : "No Results", systemImage: library.search.isEmpty ? "tray" : "magnifyingglass")
                    } description: {
                        Text(library.search.isEmpty ? "Documents in this view will appear here." : "Try a title, correspondent, tag, or collection.")
                    }.frame(maxHeight: .infinity)
                } else {
                    List(selection: $library.selection) {
                        ForEach(library.visibleDocuments) { document in
                            DocumentRow(document: document).tag(document.id)
                                .contextMenu {
                                    Button(document.favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: "star") {
                                        library.toggleFavorite(document.id)
                                    }
                                    if let url = document.previewURL {
                                        Button("Open Sample in Preview", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(url) }
                                    }
                                }
                        }
                    }.listStyle(.inset).alternatingRowBackgrounds(.disabled)
                }
                Divider()
                HStack {
                    Text("\(library.visibleDocuments.count) \(library.visibleDocuments.count == 1 ? "document" : "documents")")
                    Spacer()
                    if library.destination == .inbox { Text("Needs review") }
                    else { Text("On this Mac") }
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 15).padding(.vertical, 10)
            }
            .navigationTitle(library.destination?.title ?? "Recent")
            .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 450)
        } detail: {
            if let index = library.documents.firstIndex(where: { $0.id == library.selection }) {
                DocumentDetailView(document: $library.documents[index], collections: library.collections)
            } else {
                ContentUnavailableView("Select a Document", systemImage: "doc.text.magnifyingglass", description: Text("Preview a document and view its details."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showImportInfo = true } label: { Label("Import Document", systemImage: "plus") }
                    .help("Import Document (⌘N)").keyboardShortcut("n")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort Documents", selection: $library.newestFirst) {
                        Text("Date Added").tag(true)
                        Text("Title").tag(false)
                    }
                } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }.help("Sort Documents")
            }
        }
        .task { await library.preparePreviews() }
        .onChange(of: library.destination) { library.reconcileSelection() }
        .onChange(of: library.search) { library.reconcileSelection() }
        .onChange(of: library.visibleDocuments.map(\.id)) { library.reconcileSelection() }
        .onReceive(NotificationCenter.default.publisher(for: .stowKitSearch)) { _ in searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .stowKitGlobalSearch)) { _ in
            library.destination = .recent
            searchFocused = true
        }
        .alert("Sample Library", isPresented: $showImportInfo) {
            Button("OK", role: .cancel) { }
        } message: { Text("This first milestone previews the native StowKit experience using fictional documents. Importing your files will be available in the next milestone.") }
        .alert("Preview Unavailable", isPresented: Binding(get: { library.previewError != nil }, set: { if !$0 { library.previewError = nil } })) {
            Button("OK") { library.previewError = nil }
        } message: { Text(library.previewError ?? "") }
        .sheet(isPresented: $showCollectionSheet) {
            VStack(alignment: .leading, spacing: 18) {
                Text("New Collection").font(.headline)
                TextField("Collection name", text: $collectionName).onSubmit { createCollection() }
                Text("Collections organize documents without moving files.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { showCollectionSheet = false }
                    Button("Create", action: createCollection).keyboardShortcut(.defaultAction).disabled(!canCreateCollection)
                }
            }.padding(24).frame(width: 360)
        }
    }
    private var canCreateCollection: Bool {
        let name = collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && !library.collections.contains { $0.name.localizedCompare(name) == .orderedSame }
    }
    private func createCollection() {
        guard canCreateCollection else { return }
        let name = collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        library.collections.append(.init(name: name, symbol: "folder"))
        library.destination = .collection(name)
        collectionName = ""
        showCollectionSheet = false
    }
}

private struct DocumentRow: View {
    let document: HouseholdDocument
    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: document.isImage ? "photo" : "doc.richtext")
                .font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
                .frame(width: 30, height: 38).padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(document.title).font(.headline).lineLimit(2)
                    if document.favorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow).accessibilityLabel("Favorite") }
                }
                Text(document.correspondent).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                HStack {
                    Text(document.documentDate, format: .dateTime.month(.abbreviated).day().year())
                    Spacer(minLength: 4)
                    if document.needsReview {
                        Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.orange)
                        Text("Review")
                    } else { Text(document.isImage ? "PNG" : "PDF") }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 9).accessibilityElement(children: .combine)
    }
}
