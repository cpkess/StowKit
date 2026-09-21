import SwiftUI
import QuickLook

struct DocumentDetailView: View {
    @Binding var document: HouseholdDocument
    let collections: [LibraryCollection]
    let storage: DocumentStorageManager
    let thumbnails: ThumbnailService
    let openCopy: () -> Void
    let trashOrRestore: () -> Void
    let processing: ProcessingSnapshot?
    let textService: TextSearchService?
    let retryProcessing: (Bool) -> Void
    let analysis: AnalysisSnapshot?
    let retryAnalysis: () -> Void
    let applyAnalysis: () -> Void
    let storageState: DocumentStorageState?
    let storageError: String?
    let setPinned: (Bool) -> Void
    let removeDownload: () -> Void
    @State private var showDetails = true
    @State private var quickLookURL: URL?
    @State private var originalError: String?
    @State private var localOriginalAvailable: Bool?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(document.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                    HStack(spacing: 6) {
                        Text(document.correspondent.isEmpty ? "No correspondent" : document.correspondent)
                        Text("·")
                        Text(document.formatLabel + (document.isImage ? " image" : " document"))
                    }.font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if document.needsReview {
                    Label("Needs Review", systemImage: "circle.dotted").font(.caption).foregroundStyle(.orange)
                }
            }.padding(20)
            Divider()
            // Not VSplitView: it tore down and rebuilt the preview pane ~20 times a second while
            // the parent redrew only 3 times, restarting its load each time. With PDFView that
            // made 454 viewers in 15s, each running PDFKit's Vision analysis, and the app froze.
            // See docs/VALIDATION.md, 2026-09-21. Do not reintroduce a split view here.
            VStack(spacing: 0) {
                preview.frame(minHeight: 200, idealHeight: 390, maxHeight: .infinity)
                if showDetails {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            ProcessingInspector(documentID: document.id, snapshot: processing, service: textService,
                                isTrashed: document.trashedAt != nil, retry: retryProcessing)
                            UnderstandingInspector(snapshot: analysis, isTrashed: document.trashedAt != nil, retry: retryAnalysis, apply: applyAnalysis)
                            StorageInspector(state: storageState, error: storageError,
                                isTrashed: document.trashedAt != nil,
                                setPinned: setPinned, removeDownload: removeDownload)
                            Divider()
                            if document.trashedAt != nil {
                                HStack {
                                    Label("This document is in Trash", systemImage: "trash").foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Restore", action: trashOrRestore)
                                }
                                Divider()
                            } else if document.needsReview {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("A quick look before you stow").font(.subheadline.weight(.medium))
                                        Text("Add the details and collections you want to keep.").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Mark Reviewed") { document.needsReview = false }
                                }
                                Divider()
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Summary").font(.headline)
                                TextField("Summary", text: $document.summary, axis: .vertical)
                                    .textFieldStyle(.plain).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 11) {
                                field("Title") { TextField("Title", text: $document.title) }
                                field("Correspondent") { TextField("Correspondent", text: $document.correspondent) }
                                field("Document date") {
                                    DatePicker("Document date", selection: $document.documentDate, displayedComponents: .date).labelsHidden()
                                }
                                field("Collections") {
                                    HStack {
                                        Text(document.collections.sorted().joined(separator: ", ")).lineLimit(2)
                                        Spacer()
                                        Menu {
                                            ForEach(collections) { collection in
                                                Toggle(collection.name, isOn: Binding(get: { document.collections.contains(collection.name) }, set: { included in
                                                    if included { document.collections.insert(collection.name) }
                                                    else { document.collections.remove(collection.name) }
                                                }))
                                            }
                                        } label: { Image(systemName: "folder.badge.gearshape") }
                                        .menuStyle(.borderlessButton).fixedSize().help("Edit Collections").accessibilityLabel("Edit Collections")
                                    }
                                }
                                field("Tags") { TextField("Comma-separated tags", text: $document.tags) }
                                field("Entities") { TextField("People, products, or places", text: $document.entities) }
                            }.textFieldStyle(.roundedBorder).font(.subheadline)
                            Divider()
                            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                                field("Original file") { Text(document.originalFilename).textSelection(.enabled).lineLimit(2) }
                                field("Storage") { Label(localOriginalAvailable == true ? "Available offline" : "Original not downloaded", systemImage: localOriginalAvailable == true ? "internaldrive" : "icloud") }
                                field("File size") { Text(ByteCountFormatter.string(fromByteCount: document.fileSize, countStyle: .file)) }
                                field("Imported") { Text(document.importedAt, format: .dateTime.month().day().year()) }
                                field("Processing") { Text(processing?.progressLabel ?? "Queued") }
                            }.font(.caption).foregroundStyle(.secondary)
                        }.padding(20)
                    }.frame(minHeight: 180, idealHeight: 300, maxHeight: 350)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { document.favorite.toggle() } label: {
                    Label(document.favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: document.favorite ? "star.fill" : "star")
                }.help(document.favorite ? "Remove from Favorites" : "Add to Favorites")
                Button(action: openCopy) { Label("Open a Copy", systemImage: "arrow.up.forward.app") }
                    .keyboardShortcut("o").help("Open a Copy (⌘O) — keeps the archived original unchanged")
                Button {
                    let selected = document
                    Task {
                        do { quickLookURL = try await storage.localOriginal(for: selected); localOriginalAvailable = true }
                        catch { originalError = error.localizedDescription }
                    }
                } label: { Label("Quick Look", systemImage: "eye") }
                    .help("Quick Look")
                Button(action: trashOrRestore) {
                    Label(document.trashedAt == nil ? "Move to Trash" : "Restore", systemImage: document.trashedAt == nil ? "trash" : "arrow.uturn.backward")
                }.help(document.trashedAt == nil ? "Move to Trash" : "Restore")
                Toggle(isOn: $showDetails) { Label("Show Details", systemImage: "sidebar.right") }.help("Show Details")
            }
        }
        .quickLookPreview($quickLookURL)
        .alert("Unable to Open Original", isPresented: Binding(get: { originalError != nil }, set: { if !$0 { originalError = nil } })) {
            Button("OK") { originalError = nil }
        } message: { Text(originalError ?? "") }
    }

    private var preview: some View {
        DocumentPreview(document: document, storage: storage, thumbnails: thumbnails, localAvailable: $localOriginalAvailable)
    }
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DocumentPreview: View {
    let document: HouseholdDocument
    let storage: DocumentStorageManager
    let thumbnails: ThumbnailService
    @Binding var localAvailable: Bool?
    @State private var cloudOnly = false
    @State private var requestDownload = false
    @State private var pdfPages: Int?
    @State private var pdfLocked = false
    @State private var pageImage: NSImage?
    @State private var image: NSImage?
    @State private var failure: String?
    @State private var pageIndex = 0
    @State private var reload = 0

    var body: some View {
        Group {
            if cloudOnly {
                ContentUnavailableView {
                    Label("Original in iCloud", systemImage: "icloud.and.arrow.down")
                } description: { Text("Metadata and downloaded text are available. Download the original to preview it on this Mac.") } actions: {
                    Button("Download Original") { requestDownload = true; reload += 1 }
                }
            } else if let failure {
                ContentUnavailableView {
                    Label("Preview Unavailable", systemImage: "doc.badge.ellipsis")
                } description: { Text(failure) } actions: { Button("Retry") { reload += 1 } }
            } else if let pdfPages {
                if pdfLocked {
                    ContentUnavailableView("Password-Protected PDF", systemImage: "lock.doc", description: Text("Your original is safely archived. Open a copy in Preview to unlock it."))
                } else {
                    VStack(spacing: 0) {
                        Group {
                            if let pageImage {
                                Image(nsImage: pageImage).resizable().scaledToFit().padding(20)
                                    .accessibilityLabel("\(document.title), page \(pageIndex + 1)")
                            } else { ProgressView() }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        if pdfPages > 1 {
                            HStack {
                                Button { pageIndex = max(0, pageIndex - 1) } label: { Image(systemName: "chevron.left") }
                                    .disabled(pageIndex == 0).accessibilityLabel("Previous Page")
                                Text("Page \(pageIndex + 1) of \(pdfPages)").monospacedDigit()
                                Button { pageIndex = min(pdfPages - 1, pageIndex + 1) } label: { Image(systemName: "chevron.right") }
                                    .disabled(pageIndex == pdfPages - 1).accessibilityLabel("Next Page")
                            }.buttonStyle(.borderless).font(.caption).padding(8)
                        }
                    }
                }
            } else if let image {
                Image(nsImage: image).resizable().scaledToFit().padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityLabel(document.title + " preview")
            } else { ProgressView("Loading Preview…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .task(id: reload) {
            pdfPages = nil; pdfLocked = false; pageImage = nil; image = nil; failure = nil; pageIndex = 0; cloudOnly = false
            do {
                if try await storage.cachedOriginal(for: document) == nil {
                    localAvailable = false
                    if !requestDownload {
                        guard await storage.canDownloadOriginals() else { throw OriginalAccessError.missing }
                        cloudOnly = true; return
                    }
                    _ = try await storage.localOriginal(for: document)
                }
                localAvailable = true
                if document.isImage {
                    let data = try await thumbnails.imagePreview(for: document)
                    guard !Task.isCancelled else { return }
                    guard let decoded = NSImage(data: data) else { throw ArchiveError.invalidDocument }
                    image = decoded
                } else {
                    let outline = try await thumbnails.pdfOutline(for: document)
                    guard !Task.isCancelled else { return }
                    pdfLocked = outline.locked
                    pdfPages = outline.pages
                    if !outline.locked { try await renderPage(0) }
                }
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
        .task(id: pageIndex) {
            guard let pdfPages, !pdfLocked, pageIndex < pdfPages else { return }
            do { try await renderPage(pageIndex) }
            catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }

    private func renderPage(_ index: Int) async throws {
        let data = try await thumbnails.pagePreview(for: document, index: index)
        guard !Task.isCancelled, index == pageIndex else { return }
        guard let decoded = NSImage(data: data) else { throw ArchiveError.invalidDocument }
        pageImage = decoded
    }
}
