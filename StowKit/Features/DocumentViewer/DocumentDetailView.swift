import SwiftUI
import PDFKit
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
    @State private var showDetails = true
    @State private var quickLookURL: URL?

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
            VSplitView {
                preview.frame(minHeight: 200, idealHeight: 390, maxHeight: .infinity)
                if showDetails {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            ProcessingInspector(documentID: document.id, snapshot: processing, service: textService,
                                isTrashed: document.trashedAt != nil, retry: retryProcessing)
                            UnderstandingInspector(snapshot: analysis, isTrashed: document.trashedAt != nil, retry: retryAnalysis, apply: applyAnalysis)
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
                                field("Storage") { Label("Available offline", systemImage: "internaldrive") }
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
                Button { quickLookURL = try? storage.originalURL(for: document.relativePath) } label: { Label("Quick Look", systemImage: "eye") }
                    .help("Quick Look")
                Button(action: trashOrRestore) {
                    Label(document.trashedAt == nil ? "Move to Trash" : "Restore", systemImage: document.trashedAt == nil ? "trash" : "arrow.uturn.backward")
                }.help(document.trashedAt == nil ? "Move to Trash" : "Restore")
                Toggle(isOn: $showDetails) { Label("Show Details", systemImage: "sidebar.right") }.help("Show Details")
            }
        }
        .quickLookPreview($quickLookURL)
    }

    private var preview: some View {
        DocumentPreview(document: document, storage: storage, thumbnails: thumbnails)
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
    @State private var pdf: PDFDocument?
    @State private var image: NSImage?
    @State private var failure: String?
    @State private var pageIndex = 0
    @State private var reload = 0

    var body: some View {
        Group {
            if let failure {
                ContentUnavailableView {
                    Label("Preview Unavailable", systemImage: "doc.badge.ellipsis")
                } description: { Text(failure) } actions: { Button("Retry") { reload += 1 } }
            } else if let pdf {
                if pdf.isLocked {
                    ContentUnavailableView("Password-Protected PDF", systemImage: "lock.doc", description: Text("Your original is safely archived. Open a copy in Preview to unlock it."))
                } else {
                    VStack(spacing: 0) {
                        PDFPreview(document: pdf, pageIndex: $pageIndex)
                        if pdf.pageCount > 1 {
                            HStack {
                                Button { pageIndex = max(0, pageIndex - 1) } label: { Image(systemName: "chevron.left") }
                                    .disabled(pageIndex == 0).accessibilityLabel("Previous Page")
                                Text("Page \(pageIndex + 1) of \(pdf.pageCount)").monospacedDigit()
                                Button { pageIndex = min(pdf.pageCount - 1, pageIndex + 1) } label: { Image(systemName: "chevron.right") }
                                    .disabled(pageIndex == pdf.pageCount - 1).accessibilityLabel("Next Page")
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
            pdf = nil; image = nil; failure = nil; pageIndex = 0
            do {
                if document.isImage {
                    let data = try await thumbnails.imagePreview(for: document)
                    guard !Task.isCancelled else { return }
                    guard let decoded = NSImage(data: data) else { throw ArchiveError.invalidDocument }
                    image = decoded
                } else {
                    let url = try storage.originalURL(for: document.relativePath)
                    let loaded = try await Task.detached(priority: .userInitiated) {
                        guard let loaded = PDFDocument(url: url) else { throw ArchiveError.invalidDocument }
                        return loaded
                    }.value
                    guard !Task.isCancelled else { return }
                    pdf = loaded
                }
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}

private struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument
    @Binding var pageIndex: Int
    func makeCoordinator() -> Coordinator { Coordinator(pageIndex: $pageIndex) }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePage
        view.backgroundColor = .underPageBackgroundColor
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged(_:)), name: .PDFViewPageChanged, object: view)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.pageIndex = $pageIndex
        if view.document !== document { view.document = document }
        if let page = document.page(at: pageIndex), view.currentPage !== page { view.go(to: page) }
        view.autoScales = true
    }
    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }
    final class Coordinator: NSObject {
        var pageIndex: Binding<Int>
        init(pageIndex: Binding<Int>) { self.pageIndex = pageIndex }
        @objc func pageChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView, let page = view.currentPage,
                  let index = view.document?.index(for: page), index != NSNotFound else { return }
            DispatchQueue.main.async { [weak self] in self?.pageIndex.wrappedValue = index }
        }
    }
}
