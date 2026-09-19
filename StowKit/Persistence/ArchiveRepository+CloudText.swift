import Foundation
import SwiftData

extension ArchiveRepository {
    typealias TextUpload = ArchiveSchemaV7.TextUpload
    typealias TextDownload = ArchiveSchemaV8.TextDownload
    func queueTextUpload(_ id: UUID) throws {
        if let row = try context.fetch(FetchDescriptor<TextUpload>(predicate: #Predicate { $0.documentID == id })).first { row.operationID = UUID() }
        else { context.insert(TextUpload(documentID: id)) }
    }
    func pendingTextUploads(offset: Int = 0) throws -> [(UUID, UUID)] {
        var query = FetchDescriptor<TextUpload>(sortBy: [SortDescriptor(\.documentID)]); query.fetchLimit = 16; query.fetchOffset = offset
        return try context.fetch(query).map { ($0.documentID, $0.operationID) }
    }
    func acknowledgeTextUpload(_ operationID: UUID) throws {
        for row in try context.fetch(FetchDescriptor<TextUpload>(predicate: #Predicate { $0.operationID == operationID })) { context.delete(row) }
        try save()
    }
    func queueTextDownload(_ head: CloudTextHead) throws {
        guard head.version == 1, head.originalHash.count == 64, head.blobHash.count == 64,
              head.originalHash.allSatisfy({ $0.isHexDigit }), head.blobHash.allSatisfy({ $0.isHexDigit }),
              head.size > 0, head.size <= 64 * 1024 * 1024 else { throw SyncRecoveryError.invalidPayload }
        let hash = head.originalHash, data = try JSONEncoder().encode(head)
        if let row = try context.fetch(FetchDescriptor<TextDownload>(predicate: #Predicate { $0.sourceHash == hash })).first { row.payload = data }
        else { context.insert(TextDownload(hash: hash, payload: data)) }
    }
    func pendingTextDownloads(offset: Int = 0) throws -> [CloudTextHead] {
        var query = FetchDescriptor<TextDownload>(sortBy: [SortDescriptor(\.sourceHash)]); query.fetchLimit = 16; query.fetchOffset = offset
        return try context.fetch(query).map { try JSONDecoder().decode(CloudTextHead.self, from: $0.payload) }
    }
    func hasPendingCloudText(writable: Bool) throws -> Bool {
        try context.fetchCount(FetchDescriptor<TextDownload>()) > 0 ||
            (writable && context.fetchCount(FetchDescriptor<TextUpload>()) > 0)
    }
    func canApplyCloudText(_ head: CloudTextHead) throws -> Bool {
        guard let document = try matching(hash: head.originalHash) else { return false }
        let id = document.id
        if let job = try processingJob(id), job.snapshot.state.isActive || job.state == "queued" { return false }
        return try context.fetchCount(FetchDescriptor<TextUpload>(predicate: #Predicate { $0.documentID == id })) == 0
    }
    func applyCloudText(_ pages: [CloudTextPage], head: CloudTextHead) throws {
        do {
            guard let document = try matching(hash: head.originalHash),
                  pages.enumerated().allSatisfy({ $0.offset == $0.element.index }) else { throw SyncRecoveryError.invalidPayload }
            let hash = head.originalHash
            guard let pending = try context.fetch(FetchDescriptor<TextDownload>(predicate: #Predicate { $0.sourceHash == hash })).first,
                  try JSONDecoder().decode(CloudTextHead.self, from: pending.payload).blobHash == head.blobHash else { return }
            let id = document.id
            // Never replace text while an explicit local extraction is running or pending upload.
            if let job = try processingJob(id), job.snapshot.state.isActive || job.state == "queued" { return }
            if try context.fetchCount(FetchDescriptor<TextUpload>(predicate: #Predicate { $0.documentID == id })) > 0 { return }
            for page in try context.fetch(FetchDescriptor<Page>(predicate: #Predicate { $0.documentID == id })) { context.delete(page) }
            for page in pages { context.insert(Page(documentID: id, pageIndex: page.index, page: .init(text: page.text, method: page.method))) }
            let job: Job
            if let existing = try processingJob(id) { job = existing } else { job = Job(documentID: id); context.insert(job) }
            job.pageCount = pages.count; job.completedPages = pages.count
            job.characterCount = pages.reduce(0) { $0 + $1.text.count }; job.ocrPages = pages.filter { $0.method == .ocr }.count
            job.state = "complete"; job.lastError = nil; job.updatedAt = Date()
            markSearchChanged(id)
            context.delete(pending)
            try save()
        } catch { context.rollback(); throw error }
    }
}
