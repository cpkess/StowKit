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
    /// One-time pass for documents imported before filenames were cleaned up. Replaces a title or
    /// date only while it is still exactly what import derived from the filename, never touches a
    /// protected title, and deliberately bypasses `update`, which would record it as a manual edit
    /// and lock the title against better suggestions. Also re-queues analyses that fell back to
    /// rules, most of which Apple's model refused before the guardrail retry existed.
    func refreshAutomaticMetadataOnce() throws {
        let key = "automatic-metadata-v1"
        if try context.fetch(FetchDescriptor<Checkpoint>(predicate: #Predicate { $0.key == key })).first?.value == "done" { return }
        do {
            for record in try context.fetch(FetchDescriptor<Record>()) {
                var document = record.document
                let raw = URL(fileURLWithPath: document.originalFilename).deletingPathExtension().lastPathComponent
                let derived = FilenameMetadata(filename: document.originalFilename)
                let analysis = try analysis(document.id)
                let protected = Set(analysis?.protectedFields ?? UnderstandingPolicy.fields)
                var changed = false
                if document.title == raw, derived.title != raw, !protected.contains("title") { document.title = derived.title; changed = true }
                if document.documentDate == document.importedAt, let date = derived.date { document.documentDate = date; changed = true }
                if changed {
                    record.updateMetadata(from: document)
                    markSearchChanged(document.id)
                    try journalDocument(document)
                }
                if let analysis, document.trashedAt == nil, analysis.snapshot.result?.provider == "Local rules" {
                    analysis.revision += 1
                    analysis.state = try processingJob(document.id)?.state == "complete" ? "queued" : "waitingText"
                    analysis.error = nil
                }
            }
            if let row = try context.fetch(FetchDescriptor<Checkpoint>(predicate: #Predicate { $0.key == key })).first { row.value = "done" }
            else { context.insert(Checkpoint(key, value: "done")) }
            try save()
        } catch { context.rollback(); throw error }
    }
    /// A document from iCloud is normally understood by the Mac that added it, and the
    /// suggestions arrive as metadata. One still carrying only what import set, with its text
    /// here for longer than `grace`, never was (that Mac had no model, quit, or predates this),
    /// so this Mac does it. Two Macs doing so converge: automatic fields merge deterministically.
    @discardableResult
    func queueUnprocessedRemoteAnalyses(now: Date = Date(), grace: TimeInterval = 600) throws -> Int {
        let remote = "remote"
        var queued = 0
        for analysis in try context.fetch(FetchDescriptor<Analysis>(predicate: #Predicate { $0.state == remote })) {
            guard let document = try document(analysis.documentID), document.trashedAt == nil,
                  let job = try processingJob(document.id), job.state == "complete", job.updatedAt <= now.addingTimeInterval(-grace),
                  Self.carriesOnlyImportDetails(document) else { continue }
            analysis.state = "queued"; analysis.revision += 1; analysis.error = nil
            queued += 1
        }
        if queued > 0 { try save() }
        return queued
    }
    nonisolated static func carriesOnlyImportDetails(_ document: HouseholdDocument) -> Bool {
        let raw = URL(fileURLWithPath: document.originalFilename).deletingPathExtension().lastPathComponent
        return document.summary.isEmpty && document.correspondent.isEmpty && document.tags.isEmpty && document.collections.isEmpty
            && [document.originalFilename, raw, FilenameMetadata(filename: document.originalFilename).title].contains(document.title)
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
        let before = document, protected = Set(job.protectedFields)
        document = UnderstandingPolicy.merge(result, into: document, protected: protected)
        var result = result
        (document, result.rules) = try applyFilingRules(to: document, before: before, protected: protected)
        document.modifiedAt = Date()
        let descriptor = FetchDescriptor<Record>(predicate: #Predicate { $0.id == id })
        guard let record = try context.fetch(descriptor).first else { throw ArchiveError.missingRecord }
        record.updateMetadata(from: document)
        job.resultData = try JSONEncoder().encode(result)
        job.state = "complete"; job.error = nil; job.updatedAt = Date()
        markSearchChanged(id)
        do { try journalDocument(document); try save() }
        catch { context.rollback(); throw error }
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
