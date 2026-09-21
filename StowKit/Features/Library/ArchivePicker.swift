import SwiftUI

/// The sidebar's bottom-left control: names the archive in use and switches between archives.
/// Switching opens the chosen archive directly; its documents download on demand, like iCloud Drive.
struct ArchivePicker: View {
    @Bindable var library: LibraryStore
    @State private var open = false

    var body: some View {
        let current = library.currentArchive
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Label(current.title, systemImage: current.symbol).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
            }.contentShape(Rectangle())
        }
        .buttonStyle(.borderless).help("Choose Archive").accessibilityLabel("Archive: \(current.title)")
        .popover(isPresented: $open, arrowEdge: .top) { chooser.frame(width: 300) }
        .task(id: open) { if open && CloudSetup.containerID != nil { await library.findCloudArchives() } }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Archive").font(.headline)
            VStack(spacing: 2) {
                ForEach(library.archiveChoices) { choice in
                    Button { Task { open = false; await library.switchArchive(to: choice) } } label: {
                        HStack(spacing: 10) {
                            Image(systemName: choice.symbol).frame(width: 18).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(choice.title)
                                Text(choice.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if choice.isCurrent { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }.padding(.vertical, 5).padding(.horizontal, 6).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(choice.isCurrent)
                }
            }
            if library.cloudBusy { ProgressView("Looking for iCloud archives…").controlSize(.small) }
            Divider()
            if CloudSetup.containerID == nil {
                Text("iCloud archives need a signed build of StowKit.").font(.caption).foregroundStyle(.secondary)
            } else if library.currentArchive.kind != .thisMac {
                Text(library.cloudStatus).font(.caption).foregroundStyle(library.cloudHasError ? .orange : .secondary)
            }
            SettingsLink { Text("Archive Settings…") }.buttonStyle(.link)
        }.padding(14)
    }
}
