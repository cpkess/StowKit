import SwiftUI

/// The home page: search the whole archive, then what needs the owner, then what arrived recently.
/// It fills the detail area while nothing is selected, so opening a document replaces it.
struct HomeView: View {
    @Bindable var library: LibraryStore
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                search
                if library.isReady {
                    needsYou
                    recent
                    collections
                }
            }.padding(30).frame(maxWidth: 760, alignment: .leading)
        }.frame(maxWidth: .infinity)
            .safeAreaInset(edge: .bottom) { totals }
            .onAppear { searchFocused = true }
    }

    private var search: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("StowKit").font(.largeTitle.weight(.semibold))
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search the whole archive", text: $library.search)
                    .textFieldStyle(.plain).font(.title3).focused($searchFocused)
                    .accessibilityLabel("Search the whole archive")
                if !library.search.isEmpty {
                    Button { library.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear Search")
                }
            }.padding(12).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
            Text(library.search.isEmpty
                 ? "Titles, senders, tags, and every word StowKit has read inside your documents."
                 : "\(library.totalResults) \(library.totalResults == 1 ? "document" : "documents") — pick one from the list to open it.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var needsYou: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Needs you").font(.headline)
            if library.overview.needsAttention {
                FlowRow(spacing: 8) {
                    if library.overview.statistics.inbox > 0 {
                        chip("Inbox", count: library.overview.statistics.inbox, symbol: "tray", tint: .orange) { library.showInbox() }
                    }
                    if library.overview.overdue > 0 {
                        chip("Overdue", count: library.overview.overdue, symbol: "exclamationmark.circle", tint: .red) { library.show(upcoming: .overdue) }
                    }
                    if library.overview.dueSoon > 0 {
                        chip("Due in 30 days", count: library.overview.dueSoon, symbol: "calendar", tint: .orange) { library.show(upcoming: .dueSoon) }
                    }
                    if library.overview.expiringSoon > 0 {
                        chip("Expiring in 90 days", count: library.overview.expiringSoon, symbol: "clock.badge.exclamationmark", tint: .orange) { library.show(upcoming: .expiringSoon) }
                    }
                    if library.overview.unfiled > 0 {
                        chip("Not in a collection", count: library.overview.unfiled, symbol: "tray.2", tint: .secondary) { library.showUnfiled() }
                    }
                }
            } else {
                Label("Nothing is waiting for you.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recently added").font(.headline)
                Spacer()
                Button("See All") { library.destination = .recent }.buttonStyle(.link)
            }
            if library.recentDocuments.isEmpty {
                Text("Import documents, or drop them anywhere in this window.").foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(library.recentDocuments) { document in
                        Button { library.showDocument(document.id) } label: {
                            RecentCard(document: document, thumbnails: library.thumbnails)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var collections: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Collections").font(.headline)
            FlowRow(spacing: 8) {
                ForEach(counted) { item in
                    chip(item.name, count: item.count, symbol: symbol(item.name), tint: .accentColor) { library.showCollection(item.name) }
                }
            }
        }
    }

    /// Every collection in the sidebar, with its count, plus any name only documents use.
    private var counted: [NamedCount] {
        let counts = Dictionary(library.overview.collections.map { ($0.name, $0.count) }, uniquingKeysWith: { first, _ in first })
        var items = library.collections.map { NamedCount(name: $0.name, count: counts[$0.name] ?? 0) }
        let known = Set(library.collections.map(\.name))
        items += library.overview.collections.filter { !known.contains($0.name) }
        return items
    }
    private func symbol(_ name: String) -> String {
        library.collections.first { $0.name == name }?.symbol ?? "folder"
    }

    private var totals: some View {
        HStack(spacing: 6) {
            Text("\(library.overview.active) \(library.overview.active == 1 ? "document" : "documents")")
            Text("·")
            Text(library.overview.statistics.bytes, format: .byteCount(style: .file)) + Text(" on this Mac, Trash included")
            if library.overview.statistics.trash > 0 {
                Text("·")
                Text("\(library.overview.statistics.trash) in Trash")
            }
            Spacer()
            Text(library.cloudStatus).lineLimit(1)
        }.font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 30).padding(.vertical, 10)
            .background(.bar)
    }

    private func chip(_ title: String, count: Int, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title)
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
            }.padding(.horizontal, 11).padding(.vertical, 7)
                .background(.quaternary.opacity(0.4), in: Capsule())
        }.buttonStyle(.plain).accessibilityLabel("\(title), \(count)")
    }
}

private struct RecentCard: View {
    let document: HouseholdDocument
    let thumbnails: ThumbnailService
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Color.clear.overlay {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(systemName: document.isImage ? "photo" : "doc.richtext")
                        .font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                }
            }
            // A thumbnail scaled to fill reports its whole size; clipping alone would leave the
            // card's button claiming that much of the page. Color.clear fixes the size first.
            .frame(height: 110).frame(maxWidth: .infinity).clipped()
                .background(.quaternary.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            Text(document.title).font(.subheadline.weight(.medium)).lineLimit(2, reservesSpace: true)
            Text(document.documentDate, format: .dateTime.month(.abbreviated).day().year())
                .font(.caption).foregroundStyle(.secondary)
        }.contentShape(Rectangle()).accessibilityElement(children: .combine)
            .task(id: document.id) {
                thumbnail = nil
                if let data = try? await thumbnails.thumbnail(for: document), !Task.isCancelled { thumbnail = NSImage(data: data) }
            }
    }
}

/// Chips wrap onto as many lines as they need. SwiftUI has no flow layout of its own.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map { $0.width }.max() ?? 0, height: height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.range {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }
    private struct Row { var range: Range<Int>; var y: CGFloat; var height: CGFloat; var width: CGFloat }
    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [], start = 0, x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append(Row(range: start..<index, y: y, height: height, width: x - spacing))
                start = index; y += height + spacing; x = 0; height = 0
            }
            x += size.width + spacing
            height = max(height, size.height)
        }
        if start < subviews.endIndex {
            rows.append(Row(range: start..<subviews.endIndex, y: y, height: height, width: max(x - spacing, 0)))
        }
        return rows
    }
}
