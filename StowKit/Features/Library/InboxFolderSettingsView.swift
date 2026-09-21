import SwiftUI

struct InboxFolderSettingsView: View {
    @Bindable var library: LibraryStore
    var body: some View {
        Section("Inbox Folder") {
            if let folder = library.inboxFolderURL {
                LabeledContent("Folder", value: folder.lastPathComponent)
                Text(folder.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if !library.inboxFolderStatus.isEmpty {
                    Text(library.inboxFolderStatus).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Check Now") { library.checkInboxFolder() }
                    Button("Choose Another Folder…") { library.chooseInboxFolder() }
                    Button("Stop Using Folder") { library.stopUsingInboxFolder() }
                }
            } else {
                Button("Choose Inbox Folder…") { library.chooseInboxFolder() }.disabled(!library.isReady)
            }
            Text("StowKit imports PDFs and images added to this folder, then moves them to the Trash. Put it in iCloud Drive to add documents from your iPhone: in Files, scan or save a document into the folder. Any Mac running StowKit can take it in.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
