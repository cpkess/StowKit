import SwiftUI

/// Under the search field: a Filter menu, the active filters as removable chips, and Save View.
struct FilterBar: View {
    @Bindable var library: LibraryStore
    @State private var naming = false
    @State private var viewName = ""

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                if !library.facets.tags.isEmpty {
                    Menu("Tag") { ForEach(library.facets.tags.prefix(40), id: \.name) { tag in Button("\(tag.name) (\(tag.count))") { library.filter.tag = tag.name } } }
                }
                if !library.facets.senders.isEmpty {
                    Menu("From") { ForEach(library.facets.senders, id: \.name) { sender in Button("\(sender.name) (\(sender.count))") { library.filter.sender = sender.name } } }
                }
                if !library.facets.types.isEmpty {
                    Menu("Type") { ForEach(library.facets.types, id: \.name) { type in Button("\(type.name) (\(type.count))") { library.filter.type = type.name } } }
                }
                Menu("Date") {
                    Button("Last 30 days") { library.filter.period = .last30Days }
                    Button("This year") { library.filter.period = .thisYear }
                    Button("Last year") { library.filter.period = .lastYear }
                    if !library.facets.years.isEmpty {
                        Divider()
                        ForEach(library.facets.years, id: \.self) { year in Button(String(year)) { library.filter.period = .year(year) } }
                    }
                }
                Menu("Due & Expiring") {
                    ForEach(LibraryFilter.Upcoming.allCases, id: \.self) { upcoming in Button(upcoming.label) { library.filter.upcoming = upcoming } }
                }
                Button("Not in a Collection") { library.filter.noCollection = true }
                if !library.filter.isEmpty { Divider(); Button("Clear Filters") { library.filter = LibraryFilter() } }
            } label: { Label("Filter", systemImage: "line.3.horizontal.decrease.circle") }
                .menuStyle(.borderlessButton).fixedSize().help("Narrow this view by tag, sender, type, date, or due date")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(library.filter.parts.enumerated()), id: \.offset) { _, part in
                        Button { part.remove(&library.filter) } label: {
                            HStack(spacing: 3) { Text(part.label).lineLimit(1); Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                                .font(.caption).padding(.horizontal, 7).padding(.vertical, 3).background(.tint.opacity(0.15), in: Capsule())
                        }.buttonStyle(.plain).help("Remove this filter")
                    }
                }
            }
            if !library.filter.isEmpty || !library.search.isEmpty {
                Button("Save View…") { viewName = ""; naming = true }.buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
        .alert("Save View", isPresented: $naming) {
            TextField("Name", text: $viewName)
            Button("Save") { library.saveCurrentView(named: viewName) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Saves this view’s place, search, and filters in the sidebar.") }
    }
}

/// The sidebar's Saved and Tags sections.
struct SidebarExtras: View {
    @Bindable var library: LibraryStore
    @State private var renaming: String?
    @State private var newName = ""
    var body: some View {
        if !library.savedViews.isEmpty {
            Section("Saved") {
                ForEach(library.savedViews) { view in
                    Button { library.apply(view) } label: { Label(view.name, systemImage: "line.3.horizontal.decrease.circle") }
                        .buttonStyle(.plain)
                        .contextMenu { Button("Delete Saved View", role: .destructive) { library.deleteSavedView(view.id) } }
                }
            }
        }
        if !library.facets.tags.isEmpty {
            Section("Tags") {
                ForEach(library.facets.tags.prefix(12), id: \.name) { tag in
                    Button { library.showTag(tag.name) } label: { Label(tag.name, systemImage: "tag") }
                        .buttonStyle(.plain).badge(tag.count)
                        .contextMenu {
                            Button("Rename Tag…") { newName = tag.name; renaming = tag.name }
                            Button("Remove from All Documents", role: .destructive) { library.renameTag(tag.name, to: "") }
                        }
                }
            }
        }
        EmptyView()
            .alert("Rename Tag", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("New name", text: $newName)
                Button("Rename") { if let old = renaming { library.renameTag(old, to: newName) }; renaming = nil }
                Button("Cancel", role: .cancel) { renaming = nil }
            } message: { Text("Renames “\(renaming ?? "")” on every document outside Trash.") }
    }
}
