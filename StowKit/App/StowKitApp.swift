import SwiftUI

@main
struct StowKitApp: App {
    @State private var library = LibraryStore()
    var body: some Scene {
        Window("StowKit", id: "library") {
            LibraryView(library: library)
                .frame(minWidth: 1000, minHeight: 650)
        }
        .defaultSize(width: 1320, height: 850)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Search All Documents") {
                    NotificationCenter.default.post(name: .stowKitGlobalSearch, object: nil)
                }.keyboardShortcut("k")
                Button("Search Current View") {
                    NotificationCenter.default.post(name: .stowKitSearch, object: nil)
                }.keyboardShortcut("f")
            }
        }
        Settings {
            Form {
                Section("Local Archive") {
                    Text("Documents and metadata are stored on this Mac. Originals are preserved unchanged; opening a document creates a separate working copy.")
                    Text("Trash is recoverable and continues to use disk space. Text extraction uses local PDF text and Vision OCR. iCloud sync and AI classification are not enabled yet.")
                        .foregroundStyle(.secondary)
                    LabeledContent("Documents", value: "\(library.documents.count)")
                    LabeledContent("Originals", value: ByteCountFormatter.string(fromByteCount: library.documents.reduce(0) { $0 + $1.fileSize }, countStyle: .file))
                    Text("Archive location").font(.caption).foregroundStyle(.secondary)
                    Text(library.storage.root.path).font(.caption).textSelection(.enabled)
                }
            }.formStyle(.grouped).frame(width: 500, height: 380)
        }
    }
}

extension Notification.Name {
    static let stowKitSearch = Notification.Name("StowKit.search")
    static let stowKitGlobalSearch = Notification.Name("StowKit.globalSearch")
}
