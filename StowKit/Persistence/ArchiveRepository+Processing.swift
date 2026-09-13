import Foundation
import SwiftData

extension ArchiveRepository {
    typealias Job = ArchiveSchemaV2.ProcessingJobRecord
    typealias Page = ArchiveSchemaV2.PageTextRecord

    func document(_ id: UUID) throws -> HouseholdDocument? {
        var descriptor = FetchDescriptor<Record>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.document
    }
    func processingJob(_ id: UUID) throws -> Job? {
        var descriptor = FetchDescriptor<Job>(predicate: #Predicate { $0.documentID == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
    func processingSnapshots() throws -> [UUID: ProcessingSnapshot] {
        Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Job>()).map { ($0.documentID, $0.snapshot) })
    }
    /// Called once on launch after import recovery. Only metadata is read, never originals.
    func recoverProcessingQueue() throws {
        let records = try documents()
        let jobs = try context.fetch(FetchDescriptor<Job>())
        let known = Set(jobs.map(\.documentID))
        let trashed = Set(records.filter { $0.trashedAt != nil }.map(\.id))
        for document in records where !known.contains(document.id) {
            context.insert(Job(documentID: document.id, paused: document.trashedAt != nil))
        }
        for job in jobs {
            let state = job.snapshot.state
            if state.isActive || state == .queued || state == .paused {
                job.state = trashed.contains(job.documentID) ? ProcessingState.paused.rawValue : ProcessingState.queued.rawValue
                job.updatedAt = Date()
            }
        }
        if context.hasChanges { try save() }
    }
    func nextProcessingJob() throws -> ProcessingSnapshot? {
        let queued = ProcessingState.queued.rawValue
        var descriptor = FetchDescriptor<Job>(predicate: #Predicate { $0.state == queued }, sortBy: [SortDescriptor(\.createdAt)])
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.snapshot
    }
    @discardableResult func setProcessingState(_ id: UUID, _ state: ProcessingState, error: String? = nil) throws -> ProcessingSnapshot {
        guard let job = try processingJob(id) else { throw ArchiveError.missingRecord }
        if state == .extractingText && job.state == ProcessingState.queued.rawValue { job.attempts += 1 }
        job.failedStage = state == .failed ? job.snapshot.state.label : nil
        job.lastError = error
        job.state = state.rawValue
        job.updatedAt = Date()
        try save()
        return job.snapshot
    }
    func setPageCount(_ id: UUID, count: Int) throws -> ProcessingSnapshot {
        guard count > 0, let job = try processingJob(id) else { throw ArchiveError.invalidDocument }
        if job.pageCount != 0 && job.pageCount != count {
            throw ProcessingError.pageCountChanged
        }
        guard job.completedPages <= count else { throw ProcessingError.invalidCheckpoint }
        job.pageCount = count
        job.updatedAt = Date()
        try save()
        return job.snapshot
    }
    /// Page text and the resume checkpoint are committed in the same database transaction.
    func savePage(_ id: UUID, index: Int, result: ExtractedPage) throws -> ProcessingSnapshot {
        guard let job = try processingJob(id), index == job.completedPages, index < job.pageCount else {
            throw ProcessingError.invalidCheckpoint
        }
        context.insert(Page(documentID: id, pageIndex: index, page: result))
        job.completedPages = index + 1
        job.characterCount += result.text.count
        if result.method == .ocr { job.ocrPages += 1 }
        job.state = ProcessingState.extractingText.rawValue
        job.updatedAt = Date()
        try save()
        return job.snapshot
    }
    func retryProcessing(_ id: UUID, restart: Bool = false) throws -> ProcessingSnapshot {
        guard let job = try processingJob(id), let document = try document(id) else { throw ArchiveError.missingRecord }
        guard !job.snapshot.state.isActive else { return job.snapshot }
        if restart {
            let pages = try context.fetch(FetchDescriptor<Page>(predicate: #Predicate { $0.documentID == id }))
            for page in pages { context.delete(page) }
            job.completedPages = 0; job.pageCount = 0; job.characterCount = 0; job.ocrPages = 0
        }
        job.state = document.trashedAt == nil ? ProcessingState.queued.rawValue : ProcessingState.paused.rawValue
        job.lastError = nil; job.failedStage = nil; job.updatedAt = Date()
        try save()
        return job.snapshot
    }
}

enum ProcessingError: LocalizedError {
    case lockedPDF, invalidCheckpoint, pageCountChanged, unreadablePage, missingOriginal
    var errorDescription: String? {
        switch self {
        case .lockedPDF: "This PDF is password-protected. Open a copy, save an unlocked PDF, and import that copy to extract its text."
        case .invalidCheckpoint: "The saved processing checkpoint is invalid. Use Extract Again to start over."
        case .pageCountChanged: "The PDF page count has changed. Use Extract Again to start over."
        case .unreadablePage: "This page could not be read. Your original remains archived; retry text extraction when it is available."
        case .missingOriginal: "The archived original is unavailable. Restore the original file from your backup, then retry."
        }
    }
}
