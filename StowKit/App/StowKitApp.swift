import SwiftUI

@main
struct StowKitApp: App {
    @NSApplicationDelegateAdaptor(StowKitAppDelegate.self) private var appDelegate
    @State private var library = LibraryStore(root: CloudSetup.activeRoot)
    @State private var updater = Updater()
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
            if updater.isAvailable {
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheck)
                }
            }
            CommandGroup(after: .newItem) {
                Button("Search All Documents") {
                    NotificationCenter.default.post(name: .stowKitGlobalSearch, object: nil)
                }.keyboardShortcut("k")
                Button("Search Current View") {
                    NotificationCenter.default.post(name: .stowKitSearch, object: nil)
                }.keyboardShortcut("f")
                Divider()
                Button("Sync Now") { library.syncNow() }.disabled(!library.cloudEnabled)
            }
        }
        Settings {
            TabView {
                Form {
                    Section("Archive") {
                        Text("Your originals are never changed. Opening one gives you a separate copy to edit.")
                        Text("Documents in Trash can be restored and still use disk space. Text is read on this Mac, and suggestions come from Apple Intelligence when it is available, or from StowKit's built-in rules.")
                            .foregroundStyle(.secondary)
                        LabeledContent("Documents", value: "\(library.statistics.documents)")
                        ArchiveUsageView(library: library)
                        Button(library.isRebuildingIndex ? "Rebuilding Search Index…" : "Rebuild Search Index") { library.rebuildSearchIndex() }
                            .disabled(!library.isReady || library.isRebuildingIndex)
                        Text("Archive location").font(.caption).foregroundStyle(.secondary)
                        Text(library.storage.root.path).font(.caption).textSelection(.enabled)
                    }
                    InboxFolderSettingsView(library: library)
                    CloudSettingsView(library: library)
                    UpdateSettingsView(updater: updater)
                }.formStyle(.grouped)
                    .tabItem { Label("General", systemImage: "gearshape") }
                FilingRulesView(library: library)
                    .tabItem { Label("Rules", systemImage: "line.3.horizontal.decrease.circle") }
            }.frame(width: 640, height: 720)
        }
    }
}

extension Notification.Name {
    static let stowKitSearch = Notification.Name("StowKit.search")
    static let stowKitGlobalSearch = Notification.Name("StowKit.globalSearch")
}
