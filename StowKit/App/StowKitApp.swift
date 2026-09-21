import SwiftUI

@main
struct StowKitApp: App {
    @NSApplicationDelegateAdaptor(StowKitAppDelegate.self) private var appDelegate
    @State private var library = LibraryStore(root: CloudSetup.activeRoot)
    var body: some Scene {
        Window("StowKit", id: "library") {
            Group {
#if STOWKIT_LIVE_VERIFICATION
                Color.clear.task { await CloudLiveVerification.run() }
#elseif STOWKIT_ARCHIVE_MAINTENANCE
                Color.clear.task { await ArchiveMaintenance.run() }
#else
                if NSClassFromString("XCTestCase") != nil { Color.clear }
                else { LibraryView(library: library) }
#endif
            }
                .id(library.storage.root)
                .onReceive(NotificationCenter.default.publisher(for: .stowKitSwitchArchive)) { notification in
                    if let root = notification.object as? URL {
                        Task { await library.shutdownForSwitch(); library = LibraryStore(root: root) }
                    }
                }
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
                Divider()
                Menu("Switch Archive") {
                    ForEach(library.archiveChoices) { choice in
                        Toggle(choice.title, isOn: Binding(get: { choice.isCurrent }, set: { chosen in
                            if chosen { Task { await library.switchArchive(to: choice) } }
                        }))
                    }
                    Divider()
                    Button("Find iCloud Archives") { Task { await library.findCloudArchives() } }
                        .disabled(CloudSetup.containerID == nil)
                }
            }
        }
        Settings {
            Form {
                Section("Local Archive") {
                    Text("Your documents are stored on this Mac and are never changed. Opening one gives you a separate copy to edit.")
                    Text("Documents in Trash can be restored and still use disk space. Text is read on this Mac, and suggestions come from Apple Intelligence when it is available, or from StowKit's built-in rules. iCloud is optional.")
                        .foregroundStyle(.secondary)
                    LabeledContent("Documents", value: "\(library.statistics.documents)")
                    ArchiveUsageView(library: library)
                    Button(library.isRebuildingIndex ? "Rebuilding Search Index…" : "Rebuild Search Index") { library.rebuildSearchIndex() }
                        .disabled(!library.isReady || library.isRebuildingIndex)
                    Text("Archive location").font(.caption).foregroundStyle(.secondary)
                    Text(library.storage.root.path).font(.caption).textSelection(.enabled)
                }
                CloudSettingsView(library: library)
            }.formStyle(.grouped).frame(width: 600, height: 650)
        }
    }
}

extension Notification.Name {
    static let stowKitSearch = Notification.Name("StowKit.search")
    static let stowKitGlobalSearch = Notification.Name("StowKit.globalSearch")
}
