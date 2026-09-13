import SwiftUI

@main
struct StowKitApp: App {
    @State private var library = LibraryStore()
    var body: some Scene {
        WindowGroup {
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
                Section("Sample Library") {
                    Text("This is the StowKit native shell preview. All documents are fictional samples, and metadata edits last for this session.")
                    Text("Document importing, persistent storage, and intelligence will be added in subsequent milestones.")
                        .foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).frame(width: 440, height: 220)
        }
    }
}

extension Notification.Name {
    static let stowKitSearch = Notification.Name("StowKit.search")
    static let stowKitGlobalSearch = Notification.Name("StowKit.globalSearch")
}
