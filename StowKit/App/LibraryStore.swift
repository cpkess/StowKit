import SwiftUI
import Observation
import UniformTypeIdentifiers
import CloudKit

struct ImportIssue: Identifiable {
    let id = UUID()
    let filename: String
    let message: String
    var documentID: UUID?
}
struct ImportReport: Identifiable {
    let id = UUID()
    var imported = 0
    var duplicates = 0
    var issues: [ImportIssue] = []
}

@MainActor @Observable
final class LibraryStore {
    private(set) var documents: [HouseholdDocument] = []
    var destination: LibraryDestination? = .recent { didSet { selectedOverride = nil; refreshTextSearch() } }
    var selection: UUID?
    var search = "" { didSet { selectedOverride = nil; refreshTextSearch() } }
    var filter = LibraryFilter() { didSet { if filter != oldValue { selectedOverride = nil; refreshTextSearch() } } }
    private(set) var facets = LibraryFacets()
    private(set) var savedViews: [SavedView] = []
    var errorMessage: String?
    var cloudStatus = "iCloud is off"
    var cloudHasError = false
    var cloudReadOnly = false
    var cloudAccessSuspended = false
    var cloudEnabled = false
    var cloudBusy = false
    /// Why this Mac isn't using the iCloud archive, when the resolver decided to stay local.
    var archiveNote: String?
    /// Set when an archive holding documents could move to iCloud; the owner confirms first.
    var cloudProposal = false
    var cloudConflicts: [StoredSyncConflict] = []
    @ObservationIgnored private var cloudCoordinator: CloudSyncCoordinator?
    @ObservationIgnored private var cloudTimer: Task<Void, Never>?
    @ObservationIgnored private var accountObserver: NSObjectProtocol?
    private(set) var startupError: String?
    private(set) var isReady = false
    private(set) var isLoading = false
    private(set) var collections: [LibraryCollection] = []
    var newestFirst = true { didSet { refreshTextSearch() } }
    private(set) var isImporting = false
    private(set) var importProgress = ""
    private(set) var lastImportMessage = ""
    var importReport: ImportReport?
    private(set) var processing: [UUID: ProcessingSnapshot] = [:]
    private(set) var isSearchingText = false
    private(set) var textSearchError: String?
    private(set) var textSearchService: TextSearchService?
    private(set) var snippets: [UUID: String] = [:]
    private(set) var totalResults = 0
    private(set) var statistics = LibraryStatistics()
    private(set) var usage: ArchiveUsage?
    private(set) var isMeasuringUsage = false
    private(set) var usageError: String?
    private(set) var storageState: DocumentStorageState?
    private(set) var storageError: String?
    private(set) var pendingProcessingCount = 0
    private(set) var isLoadingMore = false
    private(set) var isRebuildingIndex = false
    private var pageLimit = 50
    var hasMore: Bool { documents.count < totalResults }
    private var selectedOverride: HouseholdDocument?
    var selectedDocument: HouseholdDocument? { documents.first { $0.id == selection } ?? (selectedOverride?.id == selection ? selectedOverride : nil) }
    private(set) var analysis: [UUID: AnalysisSnapshot] = [:]
    @ObservationIgnored private var intelligenceProcessor: DocumentIntelligenceProcessor?
    @ObservationIgnored private var processor: DocumentProcessor?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private let processingEnabled: Bool
    let storage: DocumentStorageManager
    let thumbnails: ThumbnailService
    @ObservationIgnored private var repository: ArchiveRepository?
    @ObservationIgnored private var importer: DocumentImporter?
    @ObservationIgnored private var pendingURLs: [URL] = []
    @ObservationIgnored private var inboxFolder: InboxFolder?
    @ObservationIgnored private var sharedInbox: InboxFolder?
    @ObservationIgnored private var shareObserver: NSObjectProtocol?
    private(set) var inboxFolderURL: URL?
    private(set) var inboxFolderStatus = ""
    private(set) var filingRules: [FilingRule] = []
    private(set) var rulesMessage = ""
    private(set) var organizeItems: [InboxBatchItem] = []
    private(set) var exportProgress: (done: Int, total: Int)?
    var exportResult: ExportResult?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    var isOrganizingInbox = false
    var showOrganizeInbox = false

    init(root: URL = DocumentStorageManager.defaultRoot, processingEnabled: Bool = true) {
        self.processingEnabled = processingEnabled
        storage = DocumentStorageManager(root: root)
        thumbnails = ThumbnailService(storage: storage)
    }
    func refreshCloudState() {
        cloudConflicts = (try? repository?.syncConflicts()) ?? []
        collections = (try? repository?.collections()) ?? collections
        if let id = selection { selectedOverride = try? repository?.document(id) }
        refreshTextSearch(resetLimit: false)
    }
    func connectCloud() async {
        guard let repository, let reader = textSearchService, !cloudBusy else { return }
        cloudBusy = true; defer { cloudBusy = false }
        do {
            let binding: CloudArchiveBinding
            if let existing = try repository.cloudBinding() { binding = existing.0 }
            else { binding = try await CloudSetup.privateBinding(archiveID: repository.archiveID) }
            guard CloudSetup.containerID == binding.containerID, CloudSetup.environment == binding.environment else { throw CloudArchiveError.setupRequired }
            if binding.shared { cloudAccessSuspended = true }
            let transport = CloudKitArchiveTransport(binding: binding)
            try await transport.verifyAccount()
            cloudReadOnly = !(try await transport.canWrite())
            try repository.bindCloud(binding)
            cloudEnabled = true; cloudHasError = false; cloudAccessSuspended = false; archiveNote = nil
            UserDefaults.standard.removeObject(forKey: Self.cloudPausedKey)
            await storage.setCloudTransport(transport)
            cloudCoordinator = CloudSyncCoordinator(repository: repository, storage: storage, reader: reader, transport: transport,
                onStatus: { [weak self] status, failed in self?.cloudStatus = status; self?.cloudHasError = failed },
                onUpdate: { [weak self] in self?.refreshCloudState(); self?.processUnprocessedRemote() }, onAccess: { [weak self] writable in self?.cloudReadOnly = !writable },
                onSuspended: { [weak self] in self?.cloudAccessSuspended = binding.shared; self?.cloudTimer?.cancel() })
            cloudCoordinator?.schedule()
            cloudTimer?.cancel()
            cloudTimer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { break }
                    self?.cloudCoordinator?.schedule()
                    self?.processUnprocessedRemote()
                }
            }
            if accountObserver == nil {
                accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
                    // Not `pauseCloud()`: that records an owner's pause and would leave iCloud off.
                    // Reconnecting re-verifies the account and refuses a different one.
                    Task { @MainActor in
                        guard let self else { return }
                        self.cloudAccessSuspended = binding.shared
                        await self.stopCloudTransport()
                        await self.connectCloud()
                    }
                }
            }
        } catch { cloudStatus = error.localizedDescription; cloudHasError = true }
    }
    /// Only the owner pauses iCloud. The pause is remembered so launch doesn't reconnect.
    func pauseCloud() async {
        await stopCloudTransport()
        try? repository?.disableCloud(); cloudEnabled = false
        UserDefaults.standard.set(true, forKey: Self.cloudPausedKey)
        cloudStatus = "iCloud is paused"; cloudHasError = false
    }
    private func stopCloudTransport() async {
        cloudTimer?.cancel(); cloudTimer = nil
        await cloudCoordinator?.stop(); cloudCoordinator = nil
        await storage.setCloudTransport(nil)
    }
    func shutdownForSwitch() async {
        cloudTimer?.cancel(); searchTask?.cancel()
        await cloudCoordinator?.stop(); await processor?.stop(); await intelligenceProcessor?.stop()
        inboxFolder?.stop(); sharedInbox?.stop()
        if let shareObserver { DistributedNotificationCenter.default().removeObserver(shareObserver); self.shareObserver = nil }
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver); self.accountObserver = nil }
    }
    func syncNow() { cloudCoordinator?.schedule() }

    // MARK: The one archive

    static let cloudPausedKey = "StowKitCloudPausedByOwner"
    /// This Mac's own archive ID, remembered so a stale iCloud copy of it is never reopened.
    static let thisMacArchiveKey = "StowKitThisMacArchiveID"
    private var isThisMacArchive: Bool { storage.root.standardizedFileURL == DocumentStorageManager.defaultRoot.standardizedFileURL }
    var archiveTitle: String { cloudEnabled ? (cloudReadOnly ? "Shared Household" : "iCloud") : "On This Mac" }

    /// Launch-time: find the one archive in iCloud and use it. See `ArchiveResolver`.
    private func resolveArchive() async {
        guard let repository, CloudSetup.containerID != nil else { return }
        var facts = ArchiveFacts(localArchiveID: repository.archiveID, documentCount: (try? repository.documentCount()) ?? 1,
            binding: try? repository.cloudBinding(), pausedByOwner: UserDefaults.standard.bool(forKey: Self.cloudPausedKey), privateZones: [])
        if facts.binding?.1 != true && !facts.pausedByOwner {
            do { facts.privateZones = try await CloudSetup.archives().filter { !$0.shared } }
            catch { cloudStatus = error.localizedDescription; cloudHasError = true; return }
        }
        switch ArchiveResolver.resolve(facts) {
        case .connect: await connectCloud()
        case .upload(let ask): if ask { cloudProposal = true } else { await connectCloud() }
        case .join(let binding): await openCloudArchive(binding)
        case .stayLocal(let reason): archiveNote = reason; cloudStatus = reason
        }
    }
    private func openCloudArchive(_ binding: CloudArchiveBinding) async {
        do {
            await stopCloudTransport()
            await processor?.stop(); await intelligenceProcessor?.stop()
            let root = try CloudSetup.prepareArchive(binding)
            NotificationCenter.default.post(name: .stowKitSwitchArchive, object: root)
        } catch { cloudStatus = error.localizedDescription; cloudHasError = true }
    }

    // MARK: Saved views and tags

    func apply(_ view: SavedView) {
        destination = view.destination; search = view.query; filter = view.filter
    }
    func saveCurrentView(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        storeViews(savedViews + [SavedView(name: trimmed, destination: destination ?? .recent, query: search, filter: filter)])
    }
    func deleteSavedView(_ id: UUID) { storeViews(savedViews.filter { $0.id != id }) }
    private func storeViews(_ views: [SavedView]) {
        do { try repository?.saveSavedViews(views); savedViews = views }
        catch { errorMessage = "Your saved views could not be saved.\n\n\(error.localizedDescription)" }
    }
    func showTag(_ tag: String) { destination = .recent; search = ""; filter = LibraryFilter(tag: tag) }
    func renameTag(_ old: String, to new: String) {
        guard allowCloudEdit(), let repository else { return }
        do {
            let changed = try repository.renameTag(old, to: new)
            if filter.tag?.caseInsensitiveCompare(old) == .orderedSame { filter.tag = new.isEmpty ? nil : new }
            lastImportMessage = "\(new.isEmpty ? "Removed" : "Renamed") the tag on \(changed) \(changed == 1 ? "document" : "documents")"
            refreshTextSearch(resetLimit: false); syncNow()
        } catch { errorMessage = "The tag could not be changed.\n\n\(error.localizedDescription)" }
    }

    // MARK: Filing rules

    func saveRule(_ rule: FilingRule) {
        var rules = filingRules
        if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = rule } else { rules.append(rule) }
        storeRules(rules)
    }
    func deleteRule(_ id: UUID) { storeRules(filingRules.filter { $0.id != id }) }
    func moveRules(from source: IndexSet, to destination: Int) {
        var rules = filingRules; rules.move(fromOffsets: source, toOffset: destination); storeRules(rules)
    }
    private func storeRules(_ rules: [FilingRule]) {
        do { try repository?.saveFilingRules(rules); filingRules = rules; rulesMessage = "" }
        catch { errorMessage = "Your rules could not be saved.\n\n\(error.localizedDescription)" }
    }
    func applyRulesToAll() {
        guard allowCloudEdit(), let repository else { return }
        do {
            let changed = try repository.applyFilingRulesToAll()
            rulesMessage = changed == 0 ? "No documents needed changes." : "Rules changed \(changed) \(changed == 1 ? "document" : "documents")."
            refreshTextSearch(resetLimit: false); refreshProcessingOverview(); syncNow()
        } catch { errorMessage = "Rules could not be applied.\n\n\(error.localizedDescription)" }
    }

    // MARK: Inbox folder

    func chooseInboxFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Use as Inbox Folder"
        panel.message = "Choose a folder, ideally in iCloud Drive. StowKit imports documents added to it and moves them to the Trash."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do { try inboxFolder?.use(folder) } catch { errorMessage = "StowKit can’t use that folder.\n\n\(error.localizedDescription)" }
        refreshInboxFolderState()
    }
    func stopUsingInboxFolder() { inboxFolder?.stopUsing() }
    /// Documents sent with Share → StowKit wait in the App Group drop folder until imported:
    /// immediately when the extension posts its notification, or on the next launch.
    private func startSharedInbox(_ importer: DocumentImporter) {
        guard !cloudReadOnly, !cloudAccessSuspended, let folder = ShareDropbox.folder else { return }
        sharedInbox = InboxFolder(importer: importer, fixedFolder: folder,
                                  onImported: { [weak self] in self?.inboxDidImport($0) }, onChange: {})
        sharedInbox?.start()
        shareObserver = DistributedNotificationCenter.default().addObserver(forName: ShareDropbox.notification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.sharedInbox?.scan() }
        }
    }
    func checkInboxFolder() { Task { await inboxFolder?.scan() } }
    private func refreshInboxFolderState() {
        inboxFolderURL = inboxFolder?.url; inboxFolderStatus = inboxFolder?.status ?? ""
    }
    /// Background imports update the lists but never move the owner's selection or view.
    private func inboxDidImport(_ result: ImportResult) {
        guard !result.isDuplicate else { return }
        if let snapshot = try? repository?.processingJob(result.document.id)?.snapshot { processing[result.document.id] = snapshot }
        if processingEnabled { processor?.start(); intelligenceProcessor?.start() }
        refreshProcessingOverview()
        refreshTextSearch(resetLimit: false)
        syncNow()
    }

    // MARK: Local copies (iCloud Drive–style)

    /// Cheap enough for list rows: a single file-existence check, no reads.
    func isDownloaded(_ document: HouseholdDocument) -> Bool {
        guard let url = try? storage.originalURL(for: document.relativePath) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
    func download(_ id: UUID) {
        guard let document = try? repository?.document(id) else { return }
        storageError = nil
        Task {
            do { _ = try await storage.localOriginal(for: document); refreshStorageState(id); refreshTextSearch(resetLimit: false) }
            catch { storageError = error.localizedDescription }
        }
    }
    func showHouseholdSharing() async {
        do { if let binding = try repository?.cloudBinding()?.0 { try await CloudSetup.share(binding) } }
        catch { cloudStatus = error.localizedDescription; cloudHasError = true }
    }
    func cloudConflictTitle(_ recordKey: String) -> String {
        guard recordKey.hasPrefix("document:"), let id = UUID(uuidString: String(recordKey.dropFirst(9))) else { return "Collection" }
        return (try? repository?.document(id)?.title) ?? "Document"
    }
    func resolveConflict(_ id: UUID, choice: SyncConflictChoice) {
        guard allowCloudEdit() else { return }
        do { try repository?.resolveSyncConflict(id, choosing: choice); refreshCloudState(); syncNow() }
        catch { errorMessage = error.localizedDescription }
    }
    private func allowCloudEdit() -> Bool {
        guard !cloudReadOnly, !cloudAccessSuspended else { errorMessage = "This household is read-only or access is paused."; return false }
        return true
    }
    var inboxCount: Int { statistics.inbox }
    var trashCount: Int { statistics.trash }
    var activeProcessing: ProcessingSnapshot? { processing.values.first { $0.state.isActive } }
    var visibleDocuments: [HouseholdDocument] { documents }
    private func refreshProcessingOverview() {
        guard let overview = try? repository?.processingOverview(ids: documents.map(\.id)) else { return }
        processing = overview.snapshots
        analysis = (try? repository?.analysisSnapshots(documents.map(\.id) + [selection].compactMap { $0 })) ?? [:]
        pendingProcessingCount = overview.pending
    }
    func reconcileSelection() {
        if !isSearchingText && selectedDocument == nil { selection = visibleDocuments.first?.id }
    }
    func start() async {
        guard !isReady, !isLoading else { return }
        isLoading = true
        startupError = nil
        defer { isLoading = false }
        do {
            try await storage.prepare()
            let repository = try ArchiveRepository(root: storage.root)
            let importer = DocumentImporter(repository: repository, storage: storage)
            self.repository = repository
            self.importer = importer
            do {
                let recovered = try await importer.recover()
                if recovered > 0 { lastImportMessage = "Recovered \(recovered) interrupted import(s)." }
            } catch {
                errorMessage = "Some interrupted imports need attention. Their recovery files have been kept.\n\n\(error.localizedDescription)"
            }
            // Best effort: it rolls back on failure and simply runs again on the next launch.
            try? repository.refreshAutomaticMetadataOnce()
            if isThisMacArchive { UserDefaults.standard.set(repository.archiveID.uuidString, forKey: Self.thisMacArchiveKey) }
            await purgeDeletedFiles()
            collections = try repository.collections()
            filingRules = (try? repository.filingRules()) ?? []
            savedViews = (try? repository.savedViews()) ?? []
            let container = repository.container
            textSearchService = await Task.detached { TextSearchService(modelContainer: container) }.value
            do { try await textSearchService?.configure(root: storage.root, archiveID: repository.archiveID) }
            catch { textSearchError = error.localizedDescription }
            try await textSearchService?.recoverProcessingQueue()
            try await textSearchService?.recoverAnalysisQueue()
            if let reader = textSearchService {
                intelligenceProcessor = DocumentIntelligenceProcessor(repository: repository, reader: reader, onUpdate: { [weak self] id in
                    self?.analysisDidUpdate(id)
                }, onError: { [weak self] in self?.errorMessage = $0 })
            }
            refreshProcessingOverview()
            processor = DocumentProcessor(repository: repository, storage: storage, onUpdate: { [weak self] snapshot in
                self?.processing[snapshot.id] = snapshot
                if snapshot.state == .complete, self?.processingEnabled == true { self?.intelligenceProcessor?.start() }
                if snapshot.state == .complete || snapshot.state == .failed || snapshot.state == .paused {
                    self?.refreshProcessingOverview()
                }
                if snapshot.state == .complete || snapshot.state == .failed { self?.refreshTextSearch(resetLimit: false) }
            }, onError: { [weak self] message in self?.errorMessage = message })
            isReady = true
            refreshTextSearch()
            await waitForSearch()
            reconcileSelection()
            if let binding = try repository.cloudBinding(), binding.0.shared { cloudAccessSuspended = true; cloudReadOnly = true }
            if isThisMacArchive { ArchiveCopies.retire(duplicatesOf: repository, under: storage.root) }
            await resolveArchive()
            if processingEnabled && !cloudReadOnly && !cloudAccessSuspended {
                processor?.start(); processUnprocessedRemote(); intelligenceProcessor?.start()
            }
            // Test stores run with processing off and must never see the owner's inbox folder.
            if processingEnabled {
                inboxFolder = InboxFolder(importer: importer, onImported: { [weak self] in self?.inboxDidImport($0) },
                                          onChange: { [weak self] in self?.refreshInboxFolderState() })
                refreshInboxFolderState()
                if !cloudReadOnly && !cloudAccessSuspended { inboxFolder?.start() }
                startSharedInbox(importer)
            }
        } catch { startupError = error.localizedDescription }
    }

    func binding(for document: HouseholdDocument) -> Binding<HouseholdDocument> {
        Binding(get: { self.documents.first(where: { $0.id == document.id }) ?? (self.selectedOverride?.id == document.id ? self.selectedOverride! : document) }, set: { self.update($0) })
    }
    func update(_ document: HouseholdDocument) {
        guard allowCloudEdit() else { return }
        guard let repository else { return }
        var edited = document
        edited.modifiedAt = Date()
        do {
            try repository.update(edited)
            syncNow()
            if let index = documents.firstIndex(where: { $0.id == document.id }) { documents[index] = edited }
            if selectedOverride?.id == document.id {
                selectedOverride = (edited.trashedAt != nil) == (destination == .trash) ? edited : nil
            }
            refreshTextSearch(resetLimit: false)
            if let snapshot = try repository.processingJob(document.id)?.snapshot { processing[document.id] = snapshot }
            if processingEnabled { processor?.start(); intelligenceProcessor?.start() }
            reconcileSelection()
        } catch { errorMessage = "Your change could not be saved.\n\n\(error.localizedDescription)" }
    }
    func toggleFavorite(_ id: UUID) {
        guard var document = (try? repository?.document(id)) else { return }
        document.favorite.toggle()
        update(document)
    }
    func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let repository else { return }
        do { try repository.setOriginalPinned(id, pinned); refreshStorageState(id) }
        catch { errorMessage = "Your change could not be saved.\n\n\(error.localizedDescription)" }
    }
    /// Removes this Mac's copy of an already-verified original. The document, its text, and its
    /// thumbnail stay; the bytes download again on request.
    func removeDownload(_ id: UUID) {
        guard let repository, let document = try? repository.document(id) else { return }
        storageError = nil
        Task {
            do {
                let facts = try repository.evictionFacts(id)
                try await storage.evictOriginal(document, facts: facts)
                refreshStorageState(id)
                if usage != nil { refreshUsage() }
            } catch { storageError = error.localizedDescription }
        }
    }
    func refreshStorageState(_ id: UUID) {
        guard let repository, let document = try? repository.document(id) else { return }
        Task {
            let location = await storage.originalLocation(for: document)
            let facts = try? repository.evictionFacts(id)
            let manageable = cloudEnabled && !cloudReadOnly && !cloudAccessSuspended && facts?.sharedArchive == false
            storageState = DocumentStorageState(documentID: id, location: location,
                                                pinned: facts?.pinned ?? false, manageable: manageable)
        }
    }
    /// Irreversible: removes documents in Trash from this Mac and, once synced, from iCloud and
    /// every other Mac. The views confirm before calling this.
    func deletePermanently(_ ids: [UUID]) {
        guard let repository, !ids.isEmpty else { return }
        do { try repository.permanentlyDelete(ids) }
        catch { errorMessage = "The documents could not be deleted.\n\n\(error.localizedDescription)"; return }
        if let selection, ids.contains(selection) { self.selection = nil; selectedOverride = nil }
        refreshTextSearch(resetLimit: false)
        Task { await purgeDeletedFiles(); cloudCoordinator?.schedule() }
    }
    /// Every document in Trash, not just the page the list has loaded.
    func trashedDocumentIDs() -> [UUID] {
        ((try? repository?.documents()) ?? []).filter { $0.trashedAt != nil }.map(\.id)
    }
    private func purgeDeletedFiles() async {
        guard let repository, let purges = try? repository.pendingFilePurges() else { return }
        for item in purges {
            do {
                try await storage.purgeFiles(relativePath: item.relativePath, documentID: item.id)
                try repository.completeFilePurge(item.id)
            } catch { continue }   // left on the list; retried on the next launch or sync
        }
    }
    func moveToTrash(_ id: UUID) {
        guard var document = (try? repository?.document(id)) else { return }
        document.trashedAt = Date()
        update(document)
    }
    func restore(_ id: UUID) {
        guard var document = (try? repository?.document(id)) else { return }
        document.trashedAt = nil
        update(document)
    }
    @discardableResult func createCollection(_ name: String) -> Bool {
        guard allowCloudEdit() else { return false }
        guard let repository else { return false }
        do {
            let collection = try repository.addCollection(name)
            syncNow()
            collections = try repository.collections()
            destination = .collection(collection.name)
            search = ""
            reconcileSelection()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func showDocument(_ id: UUID) {
        guard let document = (try? repository?.document(id)) else { return }
        destination = document.trashedAt == nil ? .recent : .trash
        search = ""
        selectedOverride = document
        selection = id
    }
    func openCopy(_ document: HouseholdDocument) {
        Task {
            do {
                let url = try await storage.prepareOpenCopy(document)
                NSWorkspace.shared.open(url, configuration: .init()) { _, error in
                    if let error { Task { @MainActor in self.errorMessage = error.localizedDescription } }
                }
            } catch { errorMessage = "The document could not be opened.\n\n\(error.localizedDescription)" }
        }
    }
    func enqueueImports(_ urls: [URL]) {
        guard allowCloudEdit() else { return }
        guard isReady, let importer, !urls.isEmpty else { return }
        pendingURLs.append(contentsOf: urls)
        guard !isImporting else { return }
        isImporting = true
        importReport = nil
        Task {
            var report = ImportReport()
            while !pendingURLs.isEmpty {
                let url = pendingURLs.removeFirst()
                importProgress = "Importing \(url.lastPathComponent) · \(pendingURLs.count) remaining"
                do {
                    let result = try await importer.importFile(url)
                    if result.isDuplicate {
                        report.duplicates += 1
                        report.issues.append(ImportIssue(filename: url.lastPathComponent,
                            message: result.document.trashedAt == nil ? "Already in your library as “\(result.document.title)”." : "Already in Trash as “\(result.document.title)”. Restore it from Trash.", documentID: result.document.id))
                    } else {
                        if let snapshot = try repository?.processingJob(result.document.id)?.snapshot { processing[result.document.id] = snapshot }
                        if processingEnabled { processor?.start(); intelligenceProcessor?.start() }
                        report.imported += 1
                        // Imports always appear in Inbox until manually reviewed; no AI is implied.
                        destination = .inbox
                        search = ""
                        selectedOverride = result.document
                        selection = result.document.id
                    }
                } catch {
                    report.issues.append(ImportIssue(filename: url.lastPathComponent, message: error.localizedDescription))
                }
            }
            refreshProcessingOverview()
            refreshTextSearch()
            isImporting = false
            syncNow()
            importProgress = ""
            lastImportMessage = "Imported \(report.imported) \(report.imported == 1 ? "document" : "documents")"
            if !report.issues.isEmpty { importReport = report }
        }
    }
    func retryProcessing(_ id: UUID, restart: Bool = false) {
        guard allowCloudEdit() else { return }
        guard let repository else { return }
        do {
            processing[id] = try repository.retryProcessing(id, restart: restart)
            refreshTextSearch()
            if processingEnabled { processor?.start(); intelligenceProcessor?.start() }
        } catch { errorMessage = error.localizedDescription }
    }
    /// This Mac is an edge processor for the one archive: it also makes suggestions for
    /// documents that arrived from iCloud without any. See `queueUnprocessedRemoteAnalyses`.
    private func processUnprocessedRemote() {
        guard processingEnabled, !cloudReadOnly, !cloudAccessSuspended,
              let queued = try? repository?.queueUnprocessedRemoteAnalyses(), queued > 0 else { return }
        refreshProcessingOverview()
        intelligenceProcessor?.start()
    }
    private func analysisDidUpdate(_ id: UUID) {
        syncNow()
        // Refresh metadata immediately so inspector edits cannot write an older pre-analysis
        // snapshot back while the asynchronous search refresh is still pending.
        if let document = try? repository?.document(id) {
            if let index = documents.firstIndex(where: { $0.id == id }) { documents[index] = document }
            if selectedOverride?.id == id { selectedOverride = document }
        }
        refreshProcessingOverview()
        refreshTextSearch(resetLimit: false)
        if isOrganizingInbox { refreshOrganizeItems() }
    }
    func retryAnalysis(_ id: UUID) {
        guard allowCloudEdit() else { return }
        do {
            try repository?.requestAnalysis(id)
            refreshProcessingOverview()
            if processingEnabled { intelligenceProcessor?.start() }
        } catch { errorMessage = error.localizedDescription }
    }
    // MARK: Export

    /// Everything outside Trash, as plain files in a folder the owner picks. See `ArchiveExporter`.
    func exportArchive() {
        guard let repository, let reader = textSearchService, exportTask == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "StowKit writes a new “StowKit Export” folder here with every document outside Trash, its text, and a manifest."
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let documents: [HouseholdDocument]
        do { documents = try repository.documents().filter { $0.trashedAt == nil } }
        catch { errorMessage = error.localizedDescription; return }
        let exporter = ArchiveExporter(storage: storage, reader: reader)
        exportProgress = (0, documents.count)
        exportTask = Task { [weak self] in
            let scoped = parent.startAccessingSecurityScopedResource()
            defer { if scoped { parent.stopAccessingSecurityScopedResource() } }
            do {
                let result = try await exporter.export(documents, into: parent) { done, total in
                    await MainActor.run { self?.exportProgress = (done, total) }
                }
                self?.exportResult = result
            } catch is CancellationError {
                self?.errorMessage = "Export stopped. The unfinished folder ends in “.partial”; it can be deleted."
            } catch {
                self?.errorMessage = "The export couldn’t finish. The unfinished folder ends in “.partial”.\n\n\(error.localizedDescription)"
            }
            self?.exportProgress = nil; self?.exportTask = nil
        }
    }
    func cancelExport() { exportTask?.cancel() }

    // MARK: Organize Inbox (batch)

    func refreshOrganizeItems() { organizeItems = (try? repository?.inboxBatchItems()) ?? [] }
    func suggestForAllInbox() {
        guard allowCloudEdit(), let repository else { return }
        do {
            try repository.requestAnalyses(organizeItems.map(\.id))
            refreshOrganizeItems(); refreshProcessingOverview()
            if processingEnabled { intelligenceProcessor?.start() }
        } catch { errorMessage = "Suggestions could not be requested.\n\n\(error.localizedDescription)" }
    }
    /// Accepts each chosen document's suggestion with its collection; one failure doesn't stop the rest.
    func applyOrganize(_ choices: [UUID: String]) {
        guard allowCloudEdit(), let repository else { return }
        var failed = 0
        for (id, collection) in choices {
            do { try repository.acceptSuggestion(id, collection: collection) } catch { failed += 1 }
        }
        let done = choices.count - failed
        lastImportMessage = "Organized \(done) \(done == 1 ? "document" : "documents")"
        if failed > 0 { errorMessage = "\(failed) \(failed == 1 ? "document" : "documents") couldn’t be organized and stayed in Inbox." }
        selectedOverride = nil
        refreshTextSearch(resetLimit: false); refreshProcessingOverview(); refreshOrganizeItems(); syncNow()
    }

    // MARK: Inbox review flow

    /// Present only while browsing Inbox, where each decision removes the document from the list.
    func inboxReview(for id: UUID) -> InboxReview? {
        // While the list reloads it still holds the previous view's documents, so wait for it.
        guard destination == .inbox, search.isEmpty, !isSearchingText,
              let index = documents.firstIndex(where: { $0.id == id }) else { return nil }
        let before = index > 0 ? documents[index - 1].id : nil
        let after = index + 1 < documents.count ? documents[index + 1].id : nil
        return InboxReview(position: index + 1, count: totalResults, analysis: analysis[id],
            accept: { [weak self] in self?.decide(id) { self?.applyAnalysis(id) } },
            file: { [weak self] name in self?.decide(id) {
                guard var document = try? self?.repository?.document(id) else { return }
                document.collections.insert(name); document.needsReview = false
                self?.update(document)
            } },
            done: { [weak self] in self?.decide(id) {
                guard var document = try? self?.repository?.document(id) else { return }
                document.needsReview = false
                self?.update(document)
            } },
            next: after.map { next in { [weak self] in self?.selection = next } },
            previous: before.map { previous in { [weak self] in self?.selection = previous } })
    }
    /// Runs a decision, then opens the document that followed this one (or preceded it, at the end).
    private func decide(_ id: UUID, _ action: () -> Void) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return action() }
        let following = index + 1 < documents.count ? documents[index + 1].id : (index > 0 ? documents[index - 1].id : nil)
        action()
        selectedOverride = nil
        selection = following
    }
    func applyAnalysis(_ id: UUID) {
        guard allowCloudEdit() else { return }
        do { try repository?.acceptAnalysis(id); selectedOverride = try repository?.document(id); refreshTextSearch(resetLimit: false) }
        catch { errorMessage = error.localizedDescription }
    }
    func waitForSearch() async {
        while let task = searchTask {
            let generation = searchGeneration
            await task.value
            if generation == searchGeneration { return }
        }
    }
    func loadMore() {
        guard hasMore, !isSearchingText else { return }
        pageLimit += 50
        isLoadingMore = true
        refreshTextSearch(resetLimit: false)
    }
    /// Measured on demand from Settings. Walking the archive is too expensive for every render,
    /// and a stale number would be worse than an absent one, so nothing caches it.
    func refreshUsage() {
        guard !isMeasuringUsage else { return }
        isMeasuringUsage = true
        usageError = nil
        Task {
            do { usage = try await storage.usage() }
            catch is CancellationError { }
            catch { usageError = error.localizedDescription }
            isMeasuringUsage = false
        }
    }
    func rebuildSearchIndex() {
        guard let service = textSearchService, !isRebuildingIndex else { return }
        isRebuildingIndex = true
        searchTask?.cancel()
        searchGeneration += 1
        searchTask = Task {
            do { try await service.rebuild() }
            catch {
                isRebuildingIndex = false
                isSearchingText = false
                textSearchError = error.localizedDescription
                return
            }
            isRebuildingIndex = false
            refreshTextSearch()
        }
    }
    func refreshTextSearch(resetLimit: Bool = true) {
        guard !isRebuildingIndex else { return }
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        if resetLimit { pageLimit = 50 }
        let query = search, scope = destination, sort = newestFirst, limit = pageLimit, narrowing = filter
        textSearchError = nil
        guard let service = textSearchService, isReady, !isRebuildingIndex else { isSearchingText = false; return }
        isSearchingText = true
        searchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(150))
                let page = try await service.search(query, destination: scope, filter: narrowing, newestFirst: sort, limit: limit)
                guard !Task.isCancelled, searchGeneration == generation else { return }
                documents = page.hits.map(\.document)
                if documents.contains(where: { $0.id == selectedOverride?.id }) { selectedOverride = nil }
                snippets = Dictionary(uniqueKeysWithValues: page.hits.map { ($0.document.id, $0.snippet) })
                totalResults = page.total
                statistics = page.statistics
                refreshProcessingOverview()
                isSearchingText = false
                isLoadingMore = false
                reconcileSelection()
                if let facets = try? await service.facets(), searchGeneration == generation { self.facets = facets }
            } catch is CancellationError { }
            catch {
                guard searchGeneration == generation else { return }
                isSearchingText = false
                isLoadingMore = false
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let page = try? await service.browse(destination: scope, newestFirst: sort, limit: limit), searchGeneration == generation {
                    documents = page.hits.map(\.document)
                    snippets = [:]
                    totalResults = page.total
                    refreshProcessingOverview()
                    reconcileSelection()
                }
                guard searchGeneration == generation else { return }
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    documents = []; snippets = [:]; totalResults = 0
                }
                textSearchError = "Search unavailable. \(error.localizedDescription) Use Rebuild Search Index in Settings to try again."
            }
        }
    }

    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard isReady else { return false }
        let supported = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !supported.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            var failures: [String] = []
            for provider in supported {
                do {
                    let url: URL = try await withCheckedThrowingContinuation { continuation in
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                            if let error { continuation.resume(throwing: error) }
                            else if let url = item as? URL { continuation.resume(returning: url) }
                            else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { continuation.resume(returning: url) }
                            else { continuation.resume(throwing: ArchiveError.unsupportedType) }
                        }
                    }
                    urls.append(url)
                } catch { failures.append(error.localizedDescription) }
            }
            enqueueImports(urls)
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        }
        return true
    }
}
