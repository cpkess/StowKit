import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Bindable var library: LibraryStore
    @FocusState private var searchFocused: Bool
    @State private var showImporter = false
    @State private var dropTargeted = false
    @State private var showCollectionSheet = false
    @State private var collectionName = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $library.destination) {
                Section {
                    Label("Inbox", systemImage: "tray")
                        .badge(library.inboxCount)
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
                Section {
                    Label("Trash", systemImage: "trash").badge(library.trashCount).tag(LibraryDestination.trash)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("StowKit")
            .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 260)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Label("On My Mac", systemImage: "externaldrive")
                    Spacer()
                    Button { showCollectionSheet = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("New Collection")
                        .accessibilityLabel("New Collection").disabled(!library.isReady)
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
                if let failure = library.startupError {
                    ContentUnavailableView {
                        Label("Library Unavailable", systemImage: "externaldrive.badge.exclamationmark")
                    } description: { Text(failure) } actions: {
                        Button("Try Again") { Task { await library.start() } }
                    }.frame(maxHeight: .infinity)
                } else if !library.isReady {
                    ProgressView("Opening Library…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if library.visibleDocuments.isEmpty && library.isSearchingText {
                    ProgressView("Searching Document Text…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if library.visibleDocuments.isEmpty {
                    ContentUnavailableView {
                        Label(library.search.isEmpty ? "No Documents" : "No Results", systemImage: library.search.isEmpty ? "tray" : "magnifyingglass")
                    } description: {
                        Text(library.search.isEmpty ? (library.destination == .trash ? "Documents moved to Trash stay here until you restore them." : "Drop PDFs or images here, or import documents to get started.") : "Try a title, correspondent, tag, or words inside a document.")
                    } actions: {
                        if library.search.isEmpty && library.destination != .trash {
                            Button("Import Documents") { showImporter = true }
                        }
                    }.frame(maxHeight: .infinity)
                } else {
                    List(selection: $library.selection) {
                        ForEach(library.visibleDocuments) { document in
                            DocumentRow(document: document, thumbnails: library.thumbnails, processing: library.processing[document.id], snippet: library.snippets[document.id] ?? "").tag(document.id)
                                .contextMenu {
                                    Button(document.favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: "star") {
                                        library.toggleFavorite(document.id)
                                    }
                                    Button("Open a Copy", systemImage: "arrow.up.forward.app") { library.openCopy(document) }
                                    Divider()
                                    if document.trashedAt != nil {
                                        Button("Restore", systemImage: "arrow.uturn.backward") { library.restore(document.id) }
                                    } else {
                                        Button("Move to Trash", systemImage: "trash", role: .destructive) { library.moveToTrash(document.id) }
                                    }
                                }
                        }
                    }.onDeleteCommand {
                        if let id = library.selection, library.destination != .trash { library.moveToTrash(id) }
                    }.listStyle(.inset).alternatingRowBackgrounds(.disabled)
                }
                if library.hasMore {
                    Button(library.isLoadingMore ? "Loading…" : "Load More") { library.loadMore() }
                        .disabled(library.isSearchingText).padding(8)
                }
                if library.pendingProcessingCount > 0 {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(library.activeProcessing?.progressLabel ?? "Waiting to extract text").lineLimit(1)
                        Spacer()
                        Text("\(library.pendingProcessingCount) remaining")
                    }.font(.caption).foregroundStyle(.secondary).padding(10)
                }
                if let message = library.textSearchError {
                    Text(message).font(.caption).foregroundStyle(.secondary).padding(10)
                }
                if library.isImporting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(library.importProgress).lineLimit(1).font(.caption)
                    }.padding(10)
                }
                Divider()
                HStack {
                    Text("\(library.visibleDocuments.count) of \(library.totalResults) documents")
                    Spacer()
                    if library.destination == .inbox { Text("Needs review") }
                    else { Text("On this Mac") }
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 15).padding(.vertical, 10)
            }
            .navigationTitle(library.destination?.title ?? "Recent")
            .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 450)
        } detail: {
            if let document = library.selectedDocument {
                DocumentDetailView(document: library.binding(for: document), collections: library.collections,
                    storage: library.storage, thumbnails: library.thumbnails,
                    openCopy: { library.openCopy(document) },
                    trashOrRestore: { document.trashedAt == nil ? library.moveToTrash(document.id) : library.restore(document.id) },
                    processing: library.processing[document.id], textService: library.textSearchService,
                    retryProcessing: { library.retryProcessing(document.id, restart: $0) })
                    .id(document.id)
            } else {
                ContentUnavailableView("Select a Document", systemImage: "doc.text.magnifyingglass", description: Text("Preview a document and view its details."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showImporter = true } label: { Label("Import Document", systemImage: "plus") }
                    .help("Import Document (⌘N)").keyboardShortcut("n").disabled(!library.isReady)
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
        .task { await library.start() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: DocumentStorageManager.supportedTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): library.enqueueImports(urls)
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { library.errorMessage = error.localizedDescription }
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted, perform: library.acceptDrop)
        .overlay {
            if dropTargeted && library.isReady {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 3).padding(4).allowsHitTesting(false)
            }
        }
        .onChange(of: library.destination) { library.reconcileSelection() }
        .onChange(of: library.search) { library.reconcileSelection() }
        .onChange(of: library.visibleDocuments.map(\.id)) { library.reconcileSelection() }
        .onReceive(NotificationCenter.default.publisher(for: .stowKitSearch)) { _ in searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .stowKitGlobalSearch)) { _ in
            library.destination = .recent
            searchFocused = true
        }
        .alert("StowKit", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
            Button("OK") { library.errorMessage = nil }
        } message: { Text(library.errorMessage ?? "") }
        .sheet(item: $library.importReport) { report in
            VStack(alignment: .leading, spacing: 16) {
                Text("Import Results").font(.title2.weight(.semibold))
                Text("Imported \(report.imported) · Already in archive \(report.duplicates) · Failed \(report.issues.filter { $0.documentID == nil }.count)")
                    .font(.subheadline).foregroundStyle(.secondary)
                List(report.issues) { issue in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(issue.filename).font(.headline)
                        Text(issue.message).foregroundStyle(.secondary).textSelection(.enabled)
                        if let id = issue.documentID {
                            Button("Show Document") { library.importReport = nil; library.showDocument(id) }
                        }
                    }.padding(.vertical, 5)
                }
                HStack { Spacer(); Button("Done") { library.importReport = nil }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 540, height: 380)
        }
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
        return !name.isEmpty && !library.collections.contains { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }
    private func createCollection() {
        guard canCreateCollection else { return }
        let name = collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard library.createCollection(name) else { return }
        collectionName = ""
        showCollectionSheet = false
    }
}

private struct DocumentRow: View {
    let document: HouseholdDocument
    let thumbnails: ThumbnailService
    let processing: ProcessingSnapshot?
    let snippet: String
    @State private var thumbnail: NSImage?
    private var highlightedSnippet: Text {
        var result = Text("")
        for (index, part) in snippet.components(separatedBy: "\u{E000}").enumerated() {
            if index == 0 { result = result + Text(part); continue }
            let pieces = part.components(separatedBy: "\u{E001}")
            result = result + Text(pieces[0]).bold()
            if pieces.count > 1 { result = result + Text(pieces.dropFirst().joined()) }
        }
        return result
    }
    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFit()
                } else {
                    Image(systemName: document.isImage ? "photo" : "doc.richtext")
                        .font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
                }
            }.frame(width: 30, height: 40).padding(.top, 3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(document.title).font(.headline).lineLimit(2)
                    if document.favorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow).accessibilityLabel("Favorite") }
                }
                Text(document.correspondent.isEmpty ? "No correspondent" : document.correspondent).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if !snippet.isEmpty {
                    highlightedSnippet.font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                HStack {
                    Text(document.documentDate, format: .dateTime.month(.abbreviated).day().year())
                    Spacer(minLength: 4)
                    if processing?.state == .failed {
                        Label("Text unavailable", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    } else if processing?.state.isActive == true {
                        Text("Extracting text")
                    } else if processing?.state == .queued {
                        Text("Queued")
                    } else if document.needsReview {
                        Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.orange)
                        Text("Review")
                    } else { Text(document.formatLabel) }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 9).accessibilityElement(children: .combine)
            .task(id: document.id) {
                thumbnail = nil
                if let data = try? await thumbnails.thumbnail(for: document), !Task.isCancelled { thumbnail = NSImage(data: data) }
            }
    }
}
