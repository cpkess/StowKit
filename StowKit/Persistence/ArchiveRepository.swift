import Foundation
import SwiftData

/// Only small metadata transactions run on the main actor. File I/O belongs to storage.
@MainActor final class ArchiveRepository {
    typealias Record = ArchiveSchemaV1.DocumentRecord
    let container: ModelContainer
    let archiveID: UUID
    let context: ModelContext

    init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: ArchiveSchemaV2.self)
        let configuration = ModelConfiguration("StowKit", schema: schema,
            url: root.appendingPathComponent("Library.store"), cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, migrationPlan: ArchiveMigrationPlan.self, configurations: [configuration])
        context = ModelContext(container)
        context.autosaveEnabled = false
        if let archive = try context.fetch(FetchDescriptor<ArchiveSchemaV1.ArchiveRecord>()).first {
            archiveID = archive.id
        } else {
            let archive = ArchiveSchemaV1.ArchiveRecord()
            archiveID = archive.id
            context.insert(archive)
            for collection in LibraryCollection.defaults { context.insert(ArchiveSchemaV1.CollectionRecord(collection)) }
            try context.save()
        }
    }

    func documents() throws -> [HouseholdDocument] {
        try context.fetch(FetchDescriptor<Record>(sortBy: [SortDescriptor(\.importedAt, order: .reverse)])).map(\.document)
    }
    func collections() throws -> [LibraryCollection] {
        let records = try context.fetch(FetchDescriptor<ArchiveSchemaV1.CollectionRecord>())
        let defaultOrder = LibraryCollection.defaults.map(\.name)
        return records.map { LibraryCollection(name: $0.name, symbol: $0.symbol) }.sorted {
            let lhs = defaultOrder.firstIndex(of: $0.name) ?? Int.max
            let rhs = defaultOrder.firstIndex(of: $1.name) ?? Int.max
            return lhs == rhs ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : lhs < rhs
        }
    }
    func matching(hash: String) throws -> HouseholdDocument? {
        var descriptor = FetchDescriptor<Record>(predicate: #Predicate { $0.contentHash == hash })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.document
    }
    func insert(_ document: HouseholdDocument) throws {
        // Explicit duplicate handling avoids SwiftData's unique-attribute upsert changing metadata.
        guard try matching(hash: document.contentHash) == nil else { throw ArchiveError.duplicate }
        context.insert(Record(document))
        context.insert(ArchiveSchemaV2.ProcessingJobRecord(documentID: document.id, paused: document.trashedAt != nil))
        try save()
    }
    func update(_ document: HouseholdDocument) throws {
        let id = document.id
        let descriptor = FetchDescriptor<Record>(predicate: #Predicate { $0.id == id })
        guard let record = try context.fetch(descriptor).first else { throw ArchiveError.missingRecord }
        record.updateMetadata(from: document)
        if let job = try processingJob(document.id) {
            if document.trashedAt != nil && (job.state == ProcessingState.queued.rawValue || job.snapshot.state.isActive) {
                job.state = ProcessingState.paused.rawValue
                job.updatedAt = Date()
            } else if document.trashedAt == nil && job.state == ProcessingState.paused.rawValue {
                job.state = ProcessingState.queued.rawValue
                job.updatedAt = Date()
            }
        }
        try save()
    }
    func addCollection(_ name: String) throws -> LibraryCollection {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !(try collections()).contains(where: { $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
            throw ArchiveError.invalidCollection
        }
        let collection = LibraryCollection(name: trimmed, symbol: "folder")
        context.insert(ArchiveSchemaV1.CollectionRecord(collection))
        try save()
        return collection
    }
    func save() throws {
        do { try context.save() }
        catch { context.rollback(); throw error }
    }
}

enum ArchiveError: LocalizedError {
    case duplicate, missingRecord, invalidCollection, unsupportedType, invalidDocument, changedSource, unsafePath, recoveryMismatch
    var errorDescription: String? {
        switch self {
        case .duplicate: "This document is already in the archive."
        case .missingRecord: "This document's metadata could not be found."
        case .invalidCollection: "Enter a unique collection name."
        case .unsupportedType: "Choose a PDF, JPEG, PNG, or HEIC file."
        case .invalidDocument: "The file is empty, damaged, or does not match its file type."
        case .changedSource: "The source changed while it was being copied. Please try again when it has finished saving."
        case .unsafePath: "The archive file path is invalid."
        case .recoveryMismatch: "An interrupted import could not be verified. Its recovery files have been retained."
        }
    }
}
