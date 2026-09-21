import SwiftUI

/// The sidebar's bottom-left control. StowKit has one archive, kept in iCloud with copies on this
/// Mac, so this reports where it stands rather than offering archives to choose between.
struct SyncStatusButton: View {
    @Bindable var library: LibraryStore
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Label(library.archiveTitle, systemImage: symbol).lineLimit(1)
                .foregroundStyle(library.cloudHasError ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless).help(library.cloudStatus).accessibilityLabel("\(library.archiveTitle): \(library.cloudStatus)")
        .popover(isPresented: $open, arrowEdge: .top) { details.frame(width: 300) }
    }

    private var symbol: String {
        if CloudSetup.containerID == nil { return "externaldrive" }
        if library.cloudHasError || !library.cloudEnabled { return "icloud.slash" }
        return library.cloudReadOnly ? "person.2" : "icloud"
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(library.cloudEnabled ? "Your archive is in iCloud" : "Your archive is on this Mac").font(.headline)
            if CloudSetup.containerID == nil {
                Text("This build of StowKit isn’t signed for iCloud, so the archive stays on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label(library.cloudStatus, systemImage: symbol).font(.caption)
                    .foregroundStyle(library.cloudHasError ? .orange : .secondary)
                if library.cloudEnabled {
                    Text("Documents download to this Mac when you open them. Removing a download keeps the document in iCloud.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Sync Now") { library.syncNow() }.disabled(library.cloudBusy)
                } else if library.archiveNote == nil {
                    Button("Keep Archive in iCloud…") { open = false; library.cloudProposal = true }
                        .disabled(!library.isReady || library.cloudBusy)
                }
            }
            if library.cloudBusy { ProgressView().controlSize(.small) }
            Divider()
            SettingsLink { Text("Archive Settings…") }.buttonStyle(.link)
        }.padding(14)
    }
}
