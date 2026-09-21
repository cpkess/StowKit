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
    let deletePermanently: () -> Void
    var review: InboxReview? = nil
    @State private var showDetails = true
    @State private var showMore = false
    @State private var quickLookURL: URL?
    @State private var originalError: String?
    @State private var localOriginalAvailable: Bool?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(document.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
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
                        // What the owner does comes first; how StowKit processed it is folded away.
                        VStack(alignment: .leading, spacing: 16) {
                            if document.trashedAt != nil {
                                banner(symbol: "trash", tint: .secondary, title: "In Trash",
                                       detail: "Restore it to organize it again, or delete it for good.") {
                                    HStack {
                                        Button("Delete Permanently…", role: .destructive, action: deletePermanently)
                                        Button("Restore", action: trashOrRestore)
                                    }
                                }
                            } else if let review {
                                InboxReviewCard(review: review, collections: collections)
                            } else if document.needsReview {
                                banner(symbol: "circle.fill", tint: .orange, title: "Needs review",
                                       detail: "Check the title, date, and collection, then mark it reviewed.") {
                                    Button("Mark Reviewed") { document.needsReview = false }
                                }
                            }
                            if processingNeedsAttention { processingInspector }
                            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 11) {
                                field("Title") { TextField("Title", text: $document.title) }
                                field("Date") {
                                    DatePicker("Date", selection: $document.documentDate, displayedComponents: .date).labelsHidden()
                                }
                                field("From") { TextField("Who sent or issued it", text: $document.correspondent) }
                                field("Collections") { collectionsControl }
                                field("Tags") { TextField("Separate tags with commas", text: $document.tags) }
                                field("Summary") { TextField("A sentence about this document", text: $document.summary, axis: .vertical) }
                            }.textFieldStyle(.roundedBorder).font(.subheadline)
                            UnderstandingInspector(snapshot: analysis, isTrashed: document.trashedAt != nil, retry: retryAnalysis, apply: applyAnalysis)
                            DisclosureGroup("More Details", isExpanded: $showMore) {
                                VStack(alignment: .leading, spacing: 16) {
                                    if !processingNeedsAttention { processingInspector }
                                    StorageInspector(state: storageState, error: storageError,
                                        isTrashed: document.trashedAt != nil,
                                        setPinned: setPinned, removeDownload: removeDownload)
                                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                                        field("People & things") {
                                            TextField("Names of people, products, or places", text: $document.entities)
                                                .textFieldStyle(.roundedBorder)
                                        }
                                        field("Original file") { Text(document.originalFilename).textSelection(.enabled).lineLimit(2) }
                                        field("Stored") { Label(localOriginalAvailable == true ? "On this Mac" : "In iCloud, not downloaded", systemImage: localOriginalAvailable == true ? "internaldrive" : "icloud") }
                                        field("File size") { Text(ByteCountFormatter.string(fromByteCount: document.fileSize, countStyle: .file)) }
                                        field("Added") { Text(document.importedAt, format: .dateTime.month().day().year()) }
                                    }.font(.caption).foregroundStyle(.secondary)
                                }.padding(.top, 10)
                            }.font(.subheadline)
                        }.padding(20)
                    }.frame(minHeight: 240, idealHeight: 380, maxHeight: 480)
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

    /// Header line: who it is from, its date, and its kind, skipping anything unknown.
    private var subtitle: String {
        var parts: [String] = []
        if !document.correspondent.isEmpty { parts.append(document.correspondent) }
        parts.append(document.documentDate.formatted(date: .abbreviated, time: .omitted))
        parts.append(document.formatLabel + (document.isImage ? " image" : " document"))
        return parts.joined(separator: " · ")
    }
    /// A failed or in-progress read is something to act on or wait for, so it stays in view.
    private var processingNeedsAttention: Bool {
        processing?.state == .failed || processing?.state.isActive == true
    }
    private var processingInspector: some View {
        ProcessingInspector(documentID: document.id, snapshot: processing, service: textService,
            isTrashed: document.trashedAt != nil, retry: retryProcessing)
    }
    private var collectionsControl: some View {
        HStack(spacing: 6) {
            if document.collections.isEmpty {
                Text("None yet").foregroundStyle(.secondary)
            } else {
                ForEach(document.collections.sorted(), id: \.self) { name in
                    Text(name).font(.caption).lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
            }
            Spacer(minLength: 4)
            Menu {
                ForEach(collections) { collection in
                    Toggle(collection.name, isOn: Binding(get: { document.collections.contains(collection.name) }, set: { included in
                        if included { document.collections.insert(collection.name) }
                        else { document.collections.remove(collection.name) }
                    }))
                }
            } label: {
                Label(document.collections.isEmpty ? "Add to Collection" : "Change", systemImage: "folder.badge.plus")
            }.menuStyle(.borderlessButton).fixedSize()
        }
    }
    private func banner<Action: View>(symbol: String, tint: Color, title: String, detail: String,
                                      @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: symbol == "circle.fill" ? 8 : 13)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            action()
        }.padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
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
