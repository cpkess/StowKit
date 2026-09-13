import Foundation

/// One durable job at a time. Each awaited page leaves the UI and importer free to run.
@MainActor final class DocumentProcessor {
    private let repository: ArchiveRepository
    private let storage: DocumentStorageManager
    private let extractor: any DocumentTextExtractor
    private let onUpdate: (ProcessingSnapshot) -> Void
    private let onError: (String) -> Void
    private var worker: Task<Void, Never>?

    init(repository: ArchiveRepository, storage: DocumentStorageManager,
         extractor: any DocumentTextExtractor = OCRService(),
         onUpdate: @escaping (ProcessingSnapshot) -> Void = { _ in },
         onError: @escaping (String) -> Void = { _ in }) {
        self.repository = repository; self.storage = storage; self.extractor = extractor
        self.onUpdate = onUpdate; self.onError = onError
    }
    func start() {
        guard worker == nil else { return }
        worker = Task {
            await run()
            worker = nil
        }
    }
    func waitUntilIdle() async { await worker?.value }
    func stop() async {
        worker?.cancel()
        await worker?.value
    }
    private func run() async {
        do {
            while !Task.isCancelled, let job = try repository.nextProcessingJob() {
                let id = job.id
                do {
                    guard let document = try repository.document(id) else { throw ArchiveError.missingRecord }
                    guard document.trashedAt == nil else {
                        onUpdate(try repository.setProcessingState(id, .paused))
                        continue
                    }
                    onUpdate(try repository.setProcessingState(id, .extractingText))
                    let input = ExtractionInput(documentID: id, url: try storage.originalURL(for: document.relativePath), isImage: document.isImage)
                    let count = try await extractor.pageCount(for: input)
                    try Task.checkCancellation()
                    let checkpoint = try repository.setPageCount(id, count: count)
                    onUpdate(checkpoint)
                    var paused = false
                    for index in checkpoint.completedPages..<count {
                        try Task.checkCancellation()
                        if try repository.document(id)?.trashedAt != nil { paused = true; break }
                        let page = try await extractor.extractPage(for: input, index: index)
                        try Task.checkCancellation()
                        if try repository.document(id)?.trashedAt != nil { paused = true; break }
                        onUpdate(try repository.setProcessingState(id, .savingText))
                        onUpdate(try repository.savePage(id, index: index, result: page))
                    }
                    try Task.checkCancellation()
                    if try repository.document(id)?.trashedAt != nil { paused = true }
                    onUpdate(try repository.setProcessingState(id, paused ? .paused : .complete))
                } catch is CancellationError {
                    let trashed = try repository.document(id)?.trashedAt != nil
                    onUpdate(try repository.setProcessingState(id, trashed ? .paused : .queued))
                    return
                } catch {
                    // Moving a document to Trash during an in-flight request takes precedence
                    // over that request's error, so restoring it can resume automatically.
                    if try repository.document(id)?.trashedAt != nil {
                        onUpdate(try repository.setProcessingState(id, .paused))
                    } else {
                        // A failed job never prevents the next document from being processed.
                        onUpdate(try repository.setProcessingState(id, .failed, error: error.localizedDescription))
                    }
                }
            }
        } catch {
            // A database save failure must stop the loop rather than endlessly retry the same job.
            onError("Processing paused because its progress could not be saved. Restart StowKit to resume.\n\n\(error.localizedDescription)")
        }
    }
}
