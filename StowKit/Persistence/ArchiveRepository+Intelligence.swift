import Foundation
import SwiftData

extension ArchiveRepository {
    typealias Analysis = ArchiveSchemaV4.AnalysisRecord
    func analysis(_ id: UUID) throws -> Analysis? {
        try context.fetch(FetchDescriptor<Analysis>(predicate: #Predicate { $0.documentID == id })).first
    }
    func analysisSnapshots(_ ids: [UUID]) throws -> [UUID: AnalysisSnapshot] {
        Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Analysis>(predicate: #Predicate { ids.contains($0.documentID) })).map { ($0.documentID, $0.snapshot) })
    }
    func protectManualChanges(from old: HouseholdDocument, to new: HouseholdDocument) throws {
        let record: Analysis
        if let existing = try analysis(new.id) { record = existing }
        else { record = Analysis(new.id, protected: UnderstandingPolicy.fields); context.insert(record) }
        var fields = Set(record.protectedFields)
        if old.title != new.title { fields.insert("title") }
        if old.summary != new.summary { fields.insert("summary") }
        if old.correspondent != new.correspondent { fields.insert("correspondent") }
        if old.collections != new.collections { fields.insert("collections") }
        if old.tags != new.tags { fields.insert("tags") }
        if old.needsReview != new.needsReview { fields.insert("review") }
        record.protectedFields = fields.sorted()
        if new.trashedAt != nil && ["queued", "analyzing"].contains(record.state) {
            record.state = "paused"; record.revision += 1
        } else if new.trashedAt == nil && record.state == "paused" {
            record.state = try processingJob(new.id)?.state == "complete" ? "queued" : "waitingText"
        }
    }
    func queueAnalysis(_ id: UUID, reset: Bool = false) throws {
        let record: Analysis
        if let existing = try analysis(id) { record = existing }
        else { record = Analysis(id, protected: UnderstandingPolicy.fields); context.insert(record) }
        if reset || record.state == "waitingText" {
            record.revision += 1
            record.state = reset ? "waitingText" : "queued"
            record.resultData = nil; record.error = nil
        }
    }
    func requestAnalysis(_ id: UUID) throws {
        guard let record = try analysis(id), try document(id)?.trashedAt == nil else { return }
        record.revision += 1
        record.state = try processingJob(id)?.state == "complete" ? "queued" : "waitingText"
        record.error = nil
        try save()
    }
    func nextAnalysis() throws -> Analysis? {
        let queued = "queued"
        var descriptor = FetchDescriptor<Analysis>(predicate: #Predicate { $0.state == queued }, sortBy: [SortDescriptor(\.updatedAt)])
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
    func finishAnalysis(_ id: UUID, revision: Int, result: DocumentUnderstanding) throws {
        guard let job = try analysis(id), job.revision == revision, job.state == "analyzing", var document = try document(id), document.trashedAt == nil else { return }
        document = UnderstandingPolicy.merge(result, into: document, protected: Set(job.protectedFields))
        document.modifiedAt = Date()
        let descriptor = FetchDescriptor<Record>(predicate: #Predicate { $0.id == id })
        guard let record = try context.fetch(descriptor).first else { throw ArchiveError.missingRecord }
        record.updateMetadata(from: document)
        job.resultData = try JSONEncoder().encode(result)
        job.state = "complete"; job.error = nil; job.updatedAt = Date()
        markSearchChanged(id)
        try save()
    }
    func acceptAnalysis(_ id: UUID) throws {
        guard let job = try analysis(id), let result = job.snapshot.result, let document = try document(id), document.trashedAt == nil else { return }
        // Acceptance is an explicit decision even when the automatic values already match.
        // Save these protections in the same transaction as the normal metadata update.
        var fields = Set(job.protectedFields)
        fields.insert("review")
        if !result.title.isEmpty { fields.insert("title") }
        if !result.summary.isEmpty { fields.insert("summary") }
        if !result.correspondent.isEmpty { fields.insert("correspondent") }
        if !result.collection.isEmpty { fields.insert("collections") }
        if !result.tags.isEmpty { fields.insert("tags") }
        job.protectedFields = fields.sorted()
        let edited = UnderstandingPolicy.merge(result, into: document, protected: [], explicit: true)
        try update(edited)
    }
}
