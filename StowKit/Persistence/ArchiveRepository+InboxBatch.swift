import Foundation
import SwiftData

/// One Inbox document as the batch organizer shows it.
struct InboxBatchItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let state: String
    let suggestion: DocumentUnderstanding?
    var working: Bool { ["queued", "analyzing", "waitingText"].contains(state) }
}

extension ArchiveRepository {
    /// Every document awaiting review, not just the loaded page of the list.
    func inboxBatchItems() throws -> [InboxBatchItem] {
        let records = try context.fetch(FetchDescriptor<Record>(predicate: #Predicate { $0.needsReview && $0.trashedAt == nil },
                                                                sortBy: [SortDescriptor(\.importedAt, order: .reverse)]))
        let analyses = try analysisSnapshots(records.map(\.id))
        return records.map { InboxBatchItem(id: $0.id, title: $0.title, state: analyses[$0.id]?.state ?? "", suggestion: analyses[$0.id]?.result) }
    }
    /// Queues fresh suggestions; documents already being read are left alone. Returns how many.
    @discardableResult
    func requestAnalyses(_ ids: [UUID]) throws -> Int {
        var queued = 0
        for id in ids {
            guard let record = try analysis(id), !["queued", "analyzing"].contains(record.state) else { continue }
            try requestAnalysis(id); queued += 1
        }
        return queued
    }
    /// Accepts a document's suggestion with the owner's chosen collection ("" for none), exactly
    /// as Use Suggestions does: the fields it fills become protected, and it leaves Inbox.
    func acceptSuggestion(_ id: UUID, collection: String) throws {
        guard let document = try document(id), document.trashedAt == nil else { return }
        let job = try analysis(id)
        var result = job?.snapshot.result ?? DocumentUnderstanding()
        result.collection = try collections().contains { $0.name == collection } ? collection : ""
        if let job {
            var fields = Set(job.protectedFields)
            fields.insert("review")
            if !result.title.isEmpty { fields.insert("title") }
            if !result.summary.isEmpty { fields.insert("summary") }
            if !result.correspondent.isEmpty { fields.insert("correspondent") }
            if !result.collection.isEmpty { fields.insert("collections") }
            if !result.tags.isEmpty { fields.insert("tags") }
            job.protectedFields = fields.sorted()
        }
        try update(UnderstandingPolicy.merge(result, into: document, protected: [], explicit: true))
    }
}
