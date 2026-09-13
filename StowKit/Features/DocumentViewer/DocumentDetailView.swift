import SwiftUI
import PDFKit
import QuickLook

struct DocumentDetailView: View {
    @Binding var document: HouseholdDocument
    let collections: [LibraryCollection]
    @State private var showDetails = true
    @State private var quickLookURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(document.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                    HStack(spacing: 6) {
                        Text(document.correspondent)
                        Text("·")
                        Text(document.isImage ? "PNG image" : "PDF document")
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
                            if document.needsReview {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("A quick look before you stow").font(.subheadline.weight(.medium))
                                        Text("Confirm the sample details and collections below.").font(.caption).foregroundStyle(.secondary)
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
                                if let amount = document.amount { field("Amount") { Text(amount) } }
                            }.textFieldStyle(.roundedBorder).font(.subheadline)
                            Divider()
                            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                                field("Original file") { Text(document.originalFilename).textSelection(.enabled).lineLimit(2) }
                                field("Storage") { Label("On this Mac · Sample", systemImage: "internaldrive") }
                                field("Processing") { Text(document.needsReview ? "Needs review (sample)" : "Complete (sample)") }
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
                Button {
                    if let url = document.previewURL { NSWorkspace.shared.open(url) }
                } label: { Label("Open Sample", systemImage: "arrow.up.forward.app") }
                    .disabled(document.previewURL == nil).keyboardShortcut("o").help("Open Sample in Preview (⌘O)")
                Button { quickLookURL = document.previewURL } label: { Label("Quick Look", systemImage: "eye") }
                    .disabled(document.previewURL == nil).help("Quick Look")
                Toggle(isOn: $showDetails) { Label("Show Details", systemImage: "sidebar.right") }.help("Show Details")
            }
        }
        .quickLookPreview($quickLookURL)
    }

    @ViewBuilder private var preview: some View {
        if let url = document.previewURL {
            if document.isImage {
                ImagePreview(url: url).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
            } else {
                PDFPreview(url: url)
            }
        } else {
            ContentUnavailableView("Preparing Sample Preview", systemImage: "doc")
        }
    }
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PDFPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePage
        view.backgroundColor = .underPageBackgroundColor
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        guard view.document?.documentURL != url else { return }
        view.document = PDFDocument(url: url)
        view.autoScales = true
    }
}

private struct ImagePreview: View {
    let url: URL
    var body: some View {
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFit().shadow(color: .black.opacity(0.12), radius: 3, y: 2)
                .accessibilityLabel("Sample receipt preview")
        } else {
            ContentUnavailableView("Image Unavailable", systemImage: "photo")
        }
    }
}
