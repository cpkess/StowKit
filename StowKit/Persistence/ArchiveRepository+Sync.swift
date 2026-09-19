import Foundation
import SwiftData

extension ArchiveRepository {
    typealias SyncRecord = ArchiveSchemaV5.SyncRecord

    func syncRecord(_ key: String) throws -> SyncRecord? {
        var query = FetchDescriptor<SyncRecord>(predicate: #Predicate { $0.key == key })
        query.fetchLimit = 1
        return try context.fetch(query).first
    }

    func collectionIdentity(_ name: String) throws -> UUID {
        typealias Identity = ArchiveSchemaV5.CollectionIdentity
        var query = FetchDescriptor<Identity>(predicate: #Predicate { $0.name == name })
        query.fetchLimit = 1
        if let existing = try context.fetch(query).first { return existing.id }
        let identity = Identity(name: name)
        context.insert(identity)
        return identity.id
    }

    func journalCollection(_ collection: LibraryCollection) throws {
        let id = try collectionIdentity(collection.name)
        let normalized = try ensureNormalizedCollection(collection, id: id)
        try journal(key: "collection:\(id.uuidString)", values: [
            "name": .text(normalized.name), "symbol": .text(normalized.symbol)
        ], manualFields: ["name", "symbol"])
    }

    func journalDocument(_ document: HouseholdDocument) throws {
        let protected = Set(try analysis(document.id)?.protectedFields ?? UnderstandingPolicy.fields)
        var values: [String: SyncValue] = [
            "id": .text(document.id.uuidString), "contentHash": .text(document.contentHash),
            "originalFilename": .text(document.originalFilename), "contentType": .text(document.contentType),
            "fileSize": .integer(document.fileSize), "importedAt": .date(document.importedAt),
            "title": .text(document.title), "correspondent": .text(document.correspondent),
            "documentDate": .date(document.documentDate), "summary": .text(document.summary),
            "tags": .text(document.tags), "entities": .text(document.entities),
            "favorite": .flag(document.favorite), "review": .flag(document.needsReview),
            "trashedAt": document.trashedAt.map { .date($0) } ?? .null
        ]
        var manual = protected.union(["documentDate", "entities", "favorite", "trashedAt"])
        let key = "document:\(document.id.uuidString)"
        // Retain explicit false edges after removals; absence isn't a delete operation.
        if let record = try syncRecord(key) {
            for field in try JSONDecoder().decode(SyncMetadata.self, from: record.payload).fields.keys where field.hasPrefix("membership:") {
                values[field] = .flag(false)
                if protected.contains("collections") { manual.insert(field) }
            }
        }
        let definitions = try collections()
        for name in document.collections.sorted() {
            let id = try collectionIdentity(name)
            let field = "membership:\(id.uuidString)"
            values[field] = .flag(true)
            if protected.contains("collections") { manual.insert(field) }
            // Include definitions for collections first encountered through migrated documents.
            try journalCollection(definitions.first { $0.name == name } ?? .init(name: name, symbol: "folder"))
        }
        try journal(key: key, values: values, manualFields: manual)
    }

    private func journal(key: String, values: [String: SyncValue], manualFields: Set<String>) throws {
        let existing = try syncRecord(key)
        let previous = try existing.map { try JSONDecoder().decode(SyncMetadata.self, from: $0.payload) }
        let operationID = UUID()
        var fields: [String: SyncField] = [:]
        for (key, value) in values {
            let manual = manualFields.contains(key)
            if let old = previous?.fields[key], old.value == value, old.manual == manual { fields[key] = old }
            else { fields[key] = SyncField(value: value, manual: manual, operationID: operationID) }
        }
        let metadata = SyncMetadata(archiveID: archiveID, recordKey: key, fields: fields)
        if key.hasPrefix("document:"), let id = UUID(uuidString: String(key.dropFirst(9))) { try saveMemberships(metadata, documentID: id) }
        guard metadata != previous else { return }
        for conflict in try openConflictRecords(key) {
            let observed = try JSONDecoder().decode(SyncField.self, from: conflict.observedField)
            if metadata.fields[conflict.field] != observed { conflict.status = "superseded" }
        }
        let payload = try JSONEncoder().encode(metadata)
        if let existing {
            existing.operationID = operationID; existing.payload = payload
            existing.pending = true; existing.changedAt = Date()
        } else { context.insert(SyncRecord(key: key, operationID: operationID, payload: payload)) }
    }

    func pendingSyncOperations(limit: Int = 64) throws -> [SyncOperation] {
        let blocked = Array(Set(try openConflictRecords().map(\.recordKey)))
        var query = FetchDescriptor<SyncRecord>(predicate: #Predicate { $0.pending && !blocked.contains($0.key) },
            sortBy: [SortDescriptor(\.changedAt), SortDescriptor(\.key)])
        query.fetchLimit = max(1, min(limit, 256))
        return try context.fetch(query).map {
            SyncOperation(id: $0.operationID, metadata: try JSONDecoder().decode(SyncMetadata.self, from: $0.payload))
        }
    }

    func acknowledgeSyncOperations(_ ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        let identifiers = Array(ids)
        let query = FetchDescriptor<SyncRecord>(predicate: #Predicate { identifiers.contains($0.operationID) })
        for record in try context.fetch(query) { record.pending = false }
        try save()
    }
}
