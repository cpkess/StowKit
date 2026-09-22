import Foundation
import UniformTypeIdentifiers

/// A folder StowKit takes documents from, like paperless-ngx's consume folder. Pointed at a folder
/// in iCloud Drive, it is how a phone adds to the archive today: save a scan there from Files, and
/// whichever Mac is running StowKit imports it and moves the file to the Trash.
@MainActor final class InboxFolder {
    static let bookmarkKey = "StowKitInboxFolderBookmark"
    private(set) var url: URL?
    private(set) var status = ""
    /// Injected so tests never read or erase the owner's real folder: the hosted test runner
    /// shares the app's container, and therefore its standard defaults.
    private let defaults: UserDefaults
    private let importer: DocumentImporter
    private let onImported: (ImportResult) -> Void
    private let onChange: () -> Void
    private var loop: Task<Void, Never>?
    private var scanning = false
    /// Files that failed, by path and modification date, so a bad file isn't retried every scan
    /// but a replaced one is.
    private var failed: [String: Date] = [:]
    /// The Share extension's drop folder holds StowKit's own staging copies, so imported files
    /// are deleted there; a folder the owner chose gets its files moved to the Trash instead.
    private let removesImported: Bool

    init(importer: DocumentImporter, defaults: UserDefaults = .standard,
         onImported: @escaping (ImportResult) -> Void, onChange: @escaping () -> Void) {
        self.importer = importer; self.defaults = defaults; self.onImported = onImported; self.onChange = onChange
        removesImported = false
        url = resolveBookmark()
    }
    /// A folder StowKit owns (the Share extension's drop folder): no bookmark, nothing remembered.
    init(importer: DocumentImporter, fixedFolder: URL, onImported: @escaping (ImportResult) -> Void, onChange: @escaping () -> Void) {
        self.importer = importer; defaults = UserDefaults(suiteName: "StowKitUnused") ?? .standard
        self.onImported = onImported; self.onChange = onChange
        removesImported = true
        try? FileManager.default.createDirectory(at: fixedFolder, withIntermediateDirectories: true)
        url = fixedFolder
    }

    func use(_ folder: URL) throws {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let bookmark = try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: Self.bookmarkKey)
        url = folder; failed = [:]; status = "Watching \(folder.lastPathComponent)"
        start()
    }
    func stopUsing() {
        loop?.cancel(); loop = nil
        defaults.removeObject(forKey: Self.bookmarkKey)
        url = nil; status = ""; onChange()
    }
    func start() {
        guard url != nil, loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scan()
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil }

    func scan() async {
        guard let url, !scanning else { return }
        scanning = true; defer { scanning = false; onChange() }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let listing: [URL]
        do { listing = try Self.candidates(in: url) }
        catch { status = "Can’t read \(url.lastPathComponent): \(error.localizedDescription)"; return }
        var imported = 0, waiting = 0
        for file in listing {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if failed[file.path] == modified { continue }
            guard Self.isDownloaded(file) else {
                try? FileManager.default.startDownloadingUbiquitousItem(at: file); waiting += 1; continue
            }
            do {
                let result = try await importer.importFile(file)
                // The original is verified into the archive (or already there), so the inbox
                // copy is surplus. Trash, not delete: it stays recoverable.
                if removesImported { try FileManager.default.removeItem(at: file) }
                else { try FileManager.default.trashItem(at: file, resultingItemURL: nil) }
                if !result.isDuplicate { imported += 1 }
                failed[file.path] = nil
                onImported(result)
            } catch {
                failed[file.path] = modified
            }
        }
        var parts = ["Checked \(Date().formatted(date: .omitted, time: .shortened))"]
        if imported > 0 { parts.append("imported \(imported)") }
        if waiting > 0 { parts.append("\(waiting) downloading from iCloud") }
        if !failed.isEmpty { parts.append("\(failed.count) couldn’t be imported and were left in the folder") }
        status = parts.joined(separator: " · ")
    }

    /// Supported documents directly inside the folder. Subfolders and hidden files are skipped,
    /// so a phone app's temporary files are never taken mid-write.
    nonisolated static func candidates(in folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            .filter { file in
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      let type = UTType(filenameExtension: file.pathExtension) else { return false }
                return DocumentStorageManager.supportedTypes.contains { type.conforms(to: $0) }
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    nonisolated static func isDownloaded(_ file: URL) -> Bool {
        let values = try? file.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values?.isUbiquitousItem == true else { return true }
        return values?.ubiquitousItemDownloadingStatus == .current
    }
    private func resolveBookmark() -> URL? {
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(fresh, forKey: Self.bookmarkKey)
        }
        return url
    }
}
