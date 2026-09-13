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
    var destination: LibraryDestination? = .recent
    var selection: UUID?
    var search = "" { didSet { refreshTextSearch() } }
    var errorMessage: String?
    private(set) var startupError: String?
    private(set) var isReady = false
    private(set) var isLoading = false
    private(set) var collections: [LibraryCollection] = []
    var newestFirst = true
    private(set) var isImporting = false
    private(set) var importProgress = ""
    private(set) var lastImportMessage = ""
    var importReport: ImportReport?
    private(set) var processing: [UUID: ProcessingSnapshot] = [:]
    private(set) var isSearchingText = false
    private(set) var textSearchError: String?
    private(set) var textSearchService: TextSearchService?
    private(set) var textMatches: [String: Set<UUID>] = [:]
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
    var inboxCount: Int { documents.filter { ($0.needsReview || processing[$0.id]?.state == .failed) && $0.trashedAt == nil }.count }
    var pendingProcessingCount: Int { processing.values.filter { $0.state == .queued || $0.state.isActive }.count }
    var activeProcessing: ProcessingSnapshot? { processing.values.first { $0.state.isActive } }
    private var searchTerms: [String] {
        Array(Set(search.split(whereSeparator: \.isWhitespace).map { TextNormalization.searchKey(String($0)) })).sorted()
    }
    var trashCount: Int { documents.filter { $0.trashedAt != nil }.count }
    var visibleDocuments: [HouseholdDocument] {
        documents.filter { document in
            let matchesDestination: Bool = switch destination {
            case .trash: document.trashedAt != nil
            case .inbox: document.trashedAt == nil && (document.needsReview || processing[document.id]?.state == .failed)
            case .favorites: document.trashedAt == nil && document.favorite
            case .collection(let name): document.trashedAt == nil && document.collections.contains(name)
            default: document.trashedAt == nil
            }
            return matchesDestination && searchTerms.allSatisfy {
                TextNormalization.searchKey(document.searchableText).contains($0) || textMatches[$0]?.contains(document.id) == true
            }
        }.sorted {
            if newestFirst { return $0.importedAt == $1.importedAt ? $0.id.uuidString < $1.id.uuidString : $0.importedAt > $1.importedAt }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
    func reconcileSelection() {
        if !visibleDocuments.contains(where: { $0.id == selection }) { selection = visibleDocuments.first?.id }
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
            documents = try repository.documents()
            collections = try repository.collections()
            try repository.recoverProcessingQueue()
            processing = try repository.processingSnapshots()
            let container = repository.container
            textSearchService = await Task.detached { TextSearchService(modelContainer: container) }.value
            processor = DocumentProcessor(repository: repository, storage: storage, onUpdate: { [weak self] snapshot in
                self?.processing[snapshot.id] = snapshot
                if snapshot.state == .complete || snapshot.state == .failed { self?.refreshTextSearch() }
            }, onError: { [weak self] message in self?.errorMessage = message })
            isReady = true
            if processingEnabled { processor?.start() }
            refreshTextSearch()
            reconcileSelection()
        } catch { startupError = error.localizedDescription }
    }

    func binding(for document: HouseholdDocument) -> Binding<HouseholdDocument> {
        Binding(get: { self.documents.first(where: { $0.id == document.id }) ?? document }, set: { self.update($0) })
    }
    func update(_ document: HouseholdDocument) {
        guard let repository, let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        var edited = document
        edited.modifiedAt = Date()
        do {
            try repository.update(edited)
            documents[index] = edited
            if let snapshot = try repository.processingJob(document.id)?.snapshot { processing[document.id] = snapshot }
            if processingEnabled { processor?.start() }
            reconcileSelection()
        } catch { errorMessage = "Your change could not be saved.\n\n\(error.localizedDescription)" }
    }
    func toggleFavorite(_ id: UUID) {
        guard var document = documents.first(where: { $0.id == id }) else { return }
        document.favorite.toggle()
        update(document)
    }
    func moveToTrash(_ id: UUID) {
        guard var document = documents.first(where: { $0.id == id }) else { return }
        document.trashedAt = Date()
        update(document)
    }
    func restore(_ id: UUID) {
        guard var document = documents.first(where: { $0.id == id }) else { return }
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
        guard let document = documents.first(where: { $0.id == id }) else { return }
        destination = document.trashedAt == nil ? .recent : .trash
        search = ""
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
                        documents.insert(result.document, at: 0)
                        if let snapshot = try repository?.processingJob(result.document.id)?.snapshot { processing[result.document.id] = snapshot }
                        if processingEnabled { processor?.start() }
                        report.imported += 1
                        // Imports always appear in Inbox until manually reviewed; no AI is implied.
                        destination = .inbox
                        search = ""
                        selection = result.document.id
                    }
                } catch {
                    report.issues.append(ImportIssue(filename: url.lastPathComponent, message: error.localizedDescription))
                }
            }
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
            if processingEnabled { processor?.start() }
        } catch { errorMessage = error.localizedDescription }
    }
    func refreshTextSearch() {
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let terms = searchTerms
        textMatches = [:]
        textSearchError = nil
        guard let service = textSearchService, !terms.isEmpty else { isSearchingText = false; return }
        isSearchingText = true
        searchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(150))
                let matches = try await service.matches(terms: terms)
                guard !Task.isCancelled, searchGeneration == generation else { return }
                textMatches = matches
                isSearchingText = false
                reconcileSelection()
            } catch is CancellationError { }
            catch {
                guard searchGeneration == generation else { return }
                isSearchingText = false
                textSearchError = "Document text could not be searched. Metadata results are shown."
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
