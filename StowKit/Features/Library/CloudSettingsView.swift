import SwiftUI

struct CloudSettingsView: View {
    @Bindable var library: LibraryStore
    @State private var confirmEnable = false
    var body: some View {
        Section("iCloud") {
            Label(library.cloudStatus, systemImage: library.cloudHasError ? "icloud.slash" : "icloud")
                .foregroundStyle(library.cloudHasError ? .orange : .secondary)
            if CloudSetup.containerID == nil {
                Text("This build is not configured for iCloud. A signed build with an iCloud container is required.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if library.cloudEnabled {
                    HStack {
                        Button("Sync Now") { library.syncNow() }
                        Button("Pause iCloud") { Task { await library.pauseCloud() } }
                        Button("Household Sharing…") { Task { await library.showHouseholdSharing() } }
                    }
                    if library.cloudReadOnly { Text("You have read-only access to this household.").font(.caption) }
                } else {
                    Button("Enable iCloud…") { confirmEnable = true }
                        .disabled(!library.isReady || library.cloudBusy)
                }
                Button("Find My iCloud Archives") { Task { await library.findCloudArchives() } }
                    .disabled(library.cloudBusy)
                ForEach(library.cloudArchives, id: \.zoneName) { archive in
                    Button("Open \(archive.shared ? "shared household" : "archive") · \(archive.archiveID.uuidString.prefix(8))") {
                        Task { await library.openCloudArchive(archive) }
                    }
                }
            }
            Text("Your documents, their details, and their text sync through iCloud. Reading text and making suggestions always happen on your Mac. Documents stay on this Mac unless you remove a download.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Enable iCloud for this archive?", isPresented: $confirmEnable, titleVisibility: .visible) {
            Button("Enable iCloud") { Task { await library.connectCloud() } }
        } message: {
            Text("This uploads this archive’s originals, metadata, and extracted text to your iCloud account. Sharing is invitation-only and configured separately.")
        }
        if !library.cloudConflicts.isEmpty {
            Section("Changes to Review") {
                ForEach(library.cloudConflicts) { stored in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(library.cloudConflictTitle(stored.recordKey)).font(.headline)
                        Text(stored.conflict.field.capitalized).font(.subheadline)
                        Text("On this Mac: \(display(stored.conflict.local.value))").textSelection(.enabled)
                        Text("From iCloud: \(display(stored.conflict.server.value))").textSelection(.enabled)
                        HStack {
                            Button("Keep This Mac’s Value") { library.resolveConflict(stored.id, choice: .local) }
                            Button("Use iCloud Value") { library.resolveConflict(stored.id, choice: .server) }
                        }.disabled(library.cloudReadOnly || library.cloudAccessSuspended)
                    }.padding(.vertical, 4)
                }
            }
        }
    }
    private func display(_ value: SyncValue) -> String {
        switch value {
        case .text(let text): text.isEmpty ? "(empty)" : text
        case .date(let date): date.formatted()
        case .flag(let flag): flag ? "Yes" : "No"
        case .integer(let number): String(number)
        case .null: "None"
        }
    }
}
