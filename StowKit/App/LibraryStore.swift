import SwiftUI
import Observation
import UniformTypeIdentifiers

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
    var errorMessage: String?
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

    init(root: URL = DocumentStorageManager.defaultRoot, processingEnabled: Bool = true) {
        self.processingEnabled = processingEnabled
        storage = DocumentStorageManager(root: root)
        thumbnails = ThumbnailService(storage: storage)
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
            collections = try repository.collections()
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
            if processingEnabled { processor?.start(); intelligenceProcessor?.start() }
            refreshTextSearch()
            await waitForSearch()
            reconcileSelection()
        } catch { startupError = error.localizedDescription }
    }

    func binding(for document: HouseholdDocument) -> Binding<HouseholdDocument> {
        Binding(get: { self.documents.first(where: { $0.id == document.id }) ?? (self.selectedOverride?.id == document.id ? self.selectedOverride! : document) }, set: { self.update($0) })
    }
    func update(_ document: HouseholdDocument) {
        guard let repository else { return }
        var edited = document
        edited.modifiedAt = Date()
        do {
            try repository.update(edited)
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
        guard let repository else { return false }
        do {
            let collection = try repository.addCollection(name)
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
            importProgress = ""
            lastImportMessage = "Imported \(report.imported) \(report.imported == 1 ? "document" : "documents")"
            if !report.issues.isEmpty { importReport = report }
        }
    }
    func retryProcessing(_ id: UUID, restart: Bool = false) {
        guard let repository else { return }
        do {
            processing[id] = try repository.retryProcessing(id, restart: restart)
            refreshTextSearch()
            if processingEnabled { processor?.start(); intelligenceProcessor?.start() }
        } catch { errorMessage = error.localizedDescription }
    }
    private func analysisDidUpdate(_ id: UUID) {
        // Refresh metadata immediately so inspector edits cannot write an older pre-analysis
        // snapshot back while the asynchronous search refresh is still pending.
        if let document = try? repository?.document(id) {
            if let index = documents.firstIndex(where: { $0.id == id }) { documents[index] = document }
            if selectedOverride?.id == id { selectedOverride = document }
        }
        refreshProcessingOverview()
        refreshTextSearch(resetLimit: false)
    }
    func retryAnalysis(_ id: UUID) {
        do {
            try repository?.requestAnalysis(id)
            refreshProcessingOverview()
            if processingEnabled { intelligenceProcessor?.start() }
        } catch { errorMessage = error.localizedDescription }
    }
    func applyAnalysis(_ id: UUID) {
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
        let query = search, scope = destination, sort = newestFirst, limit = pageLimit
        textSearchError = nil
        guard let service = textSearchService, isReady, !isRebuildingIndex else { isSearchingText = false; return }
        isSearchingText = true
        searchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(150))
                let page = try await service.search(query, destination: scope, newestFirst: sort, limit: limit)
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
