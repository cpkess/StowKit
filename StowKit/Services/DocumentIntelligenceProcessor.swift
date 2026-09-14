import Foundation

@MainActor final class DocumentIntelligenceProcessor {
    private let repository: ArchiveRepository
    private let reader: TextSearchService
    private let provider: any DocumentIntelligenceProvider
    private let onUpdate: (UUID) -> Void
    private let onError: (String) -> Void
    private var worker: Task<Void, Never>?
    init(repository: ArchiveRepository, reader: TextSearchService, provider: any DocumentIntelligenceProvider = LocalIntelligenceProvider(), onUpdate: @escaping (UUID) -> Void = { _ in }, onError: @escaping (String) -> Void = { _ in }) {
        self.repository = repository; self.reader = reader; self.provider = provider; self.onUpdate = onUpdate; self.onError = onError
    }
    func start() {
        guard worker == nil else { return }
        worker = Task { await run(); worker = nil }
    }
    func waitUntilIdle() async { await worker?.value }
    func stop() async { worker?.cancel(); await worker?.value }
    private func run() async {
        do {
            while !Task.isCancelled, let job = try repository.nextAnalysis() {
                let revision = job.revision, id = job.documentID
                guard let document = try repository.document(id) else { throw ArchiveError.missingRecord }
                if document.trashedAt != nil { job.state = "paused"; try repository.save(); continue }
                job.state = "analyzing"; try repository.save(); onUpdate(id)
                do {
                    let collections = try repository.collections().map(\.name)
                    let input = try await reader.analysisInput(document, collections: collections)
                    let result = try await provider.understand(input)
                    try Task.checkCancellation()
                    try repository.finishAnalysis(id, revision: revision, result: UnderstandingPolicy.validated(result, input: input))
                } catch is CancellationError {
                    if job.revision == revision && job.state == "analyzing" { job.state = "queued"; try repository.save() }
                    onUpdate(id); return
                } catch {
                    if job.revision == revision && job.state == "analyzing" {
                        job.state = "failed"; job.error = "Document analysis could not finish. You can organize it manually or try again."
                        try repository.save()
                    }
                }
                onUpdate(id)
            }
        } catch { onError("Document analysis paused because its progress could not be saved. Restart StowKit to resume.\n\n\(error.localizedDescription)") }
    }
}
