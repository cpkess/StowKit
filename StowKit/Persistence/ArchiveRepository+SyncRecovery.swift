import Foundation
import SwiftData

extension ArchiveRepository {
    typealias Checkpoint = ArchiveSchemaV6.SyncCheckpoint
    typealias Baseline = ArchiveSchemaV6.ServerBaseline
    typealias Conflict = ArchiveSchemaV6.ConflictRecord

    private func checkpoint(_ key: String) throws -> Checkpoint {
        var query = FetchDescriptor<Checkpoint>(predicate: #Predicate { $0.key == key }); query.fetchLimit = 1
        if let value = try context.fetch(query).first { return value }
        let value = Checkpoint(key); context.insert(value); return value
    }

    /// Explicit activation work, never called on normal app launch. Each call commits one bounded page.
    /// Imported records behind the cursor already get their journal in the import transaction.
    @discardableResult func backfillSyncBatch(limit: Int = 64) throws -> Bool {
        do {
            let phase = try checkpoint("sync-backfill-phase-v7")
            if phase.value == "complete" { return true }
            let cursor = try checkpoint("sync-backfill-cursor-v7")
            let after = cursor.value
            let size = max(1, min(limit, 256))
            if phase.value.isEmpty {
                var query = FetchDescriptor<ArchiveSchemaV1.CollectionRecord>(predicate: #Predicate { $0.name > after }, sortBy: [SortDescriptor(\.name)])
                query.fetchLimit = size
                let batch = try context.fetch(query)
                for collection in batch { try journalCollection(.init(name: collection.name, symbol: collection.symbol)) }
                if let last = batch.last { cursor.value = last.name }
                if batch.count < size { phase.value = "documents"; cursor.value = "" }
            } else {
                var query = FetchDescriptor<Record>(predicate: #Predicate { $0.contentHash > after }, sortBy: [SortDescriptor(\.contentHash)])
                query.fetchLimit = size
                let batch = try context.fetch(query)
                for record in batch {
                    try journalDocument(record.document)
                    if try processingJob(record.id)?.state == "complete" { try queueTextUpload(record.id) }
                }
                if let last = batch.last { cursor.value = last.contentHash }
                if batch.count < size { phase.value = "complete" }
            }
            try save()
            return phase.value == "complete"
        } catch { context.rollback(); throw error }
    }

    func incomingSyncToken() throws -> String {
        let key = "incoming-token"
        return try context.fetch(FetchDescriptor<Checkpoint>(predicate: #Predicate { $0.key == key })).first?.value ?? ""
    }

    func serverBaseline(_ key: String) throws -> Baseline? {
        var query = FetchDescriptor<Baseline>(predicate: #Predicate { $0.key == key }); query.fetchLimit = 1
        return try context.fetch(query).first
    }

    /// Complete pages, including baseline, metadata, index receipts, conflicts, and token, are atomic.
    /// Only existing document identities and known collection memberships are supported in this slice.
    func applyIncomingPage(_ page: IncomingMetadataPage) throws {
        do {
            guard !page.nextToken.isEmpty, page.nextToken != page.previousToken,
                  page.records.count <= 64,
                  Set(page.records.map(\.recordKey)).count == page.records.count else { throw SyncRecoveryError.invalidPayload }
            let token = try checkpoint("incoming-token")
            guard token.value == page.previousToken else { throw SyncRecoveryError.stalePage }
            for metadata in page.records {
                if metadata.recordKey.hasPrefix("collection:") { try applyIncomingCollection(metadata) }
                else { try applyIncoming(metadata) }
            }
            token.value = page.nextToken
            try save()
        } catch { context.rollback(); throw error }
    }

    func applyIncoming(_ remote: SyncMetadata) throws {
        guard remote.formatVersion == 1, remote.archiveID == archiveID else { throw SyncRecoveryError.invalidPayload }
        guard remote.recordKey.hasPrefix("document:"),
              let id = UUID(uuidString: String(remote.recordKey.dropFirst(9))),
              let document = try document(id) else { throw SyncRecoveryError.unsupportedRecord }
        if try syncRecord(remote.recordKey) == nil { try journalDocument(document) }
        guard let row = try syncRecord(remote.recordKey) else { throw SyncRecoveryError.invalidPayload }
        let local = try JSONDecoder().decode(SyncMetadata.self, from: row.payload)
        try validateIncoming(remote, against: local)
        let baseline = try serverBaseline(remote.recordKey)
        let base = try baseline.map { try JSONDecoder().decode(SyncMetadata.self, from: $0.payload).fields } ?? [:]
        let merge = SyncMergePolicy.merge(base: base, local: local.fields, server: remote.fields)
        var mergedFields = merge.fields
        var newConflicts = merge.conflicts
        // The displayed server value isn't a resolution: keep the hidden local alternative
        // across later remote edits, rather than treating it as an unchanged local field.
        for pending in try openConflictRecords(remote.recordKey) {
            let alternatives = try JSONDecoder().decode(SyncConflict.self, from: pending.payload)
            guard let incoming = remote.fields[pending.field] else { continue }
            if incoming.value == alternatives.local.value, incoming.manual {
                mergedFields[pending.field] = incoming
                pending.status = "resolved"
            } else if incoming != base[pending.field], incoming.manual {
                mergedFields[pending.field] = incoming
                newConflicts.removeAll { $0.field == pending.field }
                newConflicts.append(SyncConflict(field: pending.field, local: alternatives.local, server: incoming))
            } else {
                mergedFields[pending.field] = local.fields[pending.field]
            }
        }
        let updated = SyncMetadata(archiveID: archiveID, recordKey: remote.recordKey, fields: mergedFields)
        try saveMemberships(updated, documentID: document.id)
        try materialize(updated, document: document)
        // Keep old alternatives as history when a newer field supersedes them.
        for conflict in try openConflictRecords(remote.recordKey) {
            let observed = try JSONDecoder().decode(SyncField.self, from: conflict.observedField)
            if mergedFields[conflict.field] != observed { conflict.status = "superseded" }
        }
        for conflict in newConflicts {
            let payload = try JSONEncoder().encode(conflict)
            let existing = try openConflictRecords(remote.recordKey)
            if !existing.contains(where: { (try? JSONDecoder().decode(SyncConflict.self, from: $0.payload)) == conflict }) {
                context.insert(Conflict(recordKey: remote.recordKey, conflict: conflict, payload: payload,
                    observedField: try JSONEncoder().encode(mergedFields[conflict.field])))
            }
        }
        row.payload = try JSONEncoder().encode(updated)
        row.operationID = UUID(); row.changedAt = Date()
        row.pending = updated.fields != remote.fields
        let remoteData = try JSONEncoder().encode(remote)
        if let baseline { baseline.payload = remoteData }
        else { context.insert(Baseline(key: remote.recordKey, payload: remoteData)) }
    }

    private func validateIncoming(_ remote: SyncMetadata, against local: SyncMetadata) throws {
        guard try JSONEncoder().encode(remote).count <= 1_048_576,
              remote.fields.count <= 1024 else { throw SyncRecoveryError.invalidPayload }
        let immutable = ["id", "contentHash", "originalFilename", "contentType", "fileSize", "importedAt"]
        for key in immutable where remote.fields[key]?.value != local.fields[key]?.value { throw SyncRecoveryError.invalidPayload }
        for (key, old) in local.fields where !key.hasPrefix("membership:") {
            guard let incoming = remote.fields[key], Self.sameType(old.value, incoming.value) else { throw SyncRecoveryError.invalidPayload }
        }
        for (key, value) in remote.fields {
            guard value.algorithmVersion > 0 else { throw SyncRecoveryError.invalidPayload }
            if key.hasPrefix("membership:") {
                guard case .flag = value.value,
                      let id = UUID(uuidString: String(key.dropFirst(11))) else { throw SyncRecoveryError.invalidPayload }
                let query = FetchDescriptor<ArchiveSchemaV5.CollectionIdentity>(predicate: #Predicate { $0.id == id })
                guard try context.fetchCount(query) == 1 else { throw SyncRecoveryError.unsupportedRecord }
            } else if local.fields[key] == nil { throw SyncRecoveryError.invalidPayload }
            if case .date(let date) = value.value, !date.timeIntervalSince1970.isFinite { throw SyncRecoveryError.invalidPayload }
        }
    }

    private static func sameType(_ a: SyncValue, _ b: SyncValue) -> Bool {
        switch (a, b) {
        case (.text, .text), (.flag, .flag), (.integer, .integer), (.date, .date), (.null, .null), (.null, .date), (.date, .null): true
        default: false
        }
    }

    private func materialize(_ metadata: SyncMetadata, document old: HouseholdDocument) throws {
        var document = old
        let fields = metadata.fields
        func text(_ key: String) throws -> String { guard case .text(let value) = fields[key]?.value else { throw SyncRecoveryError.invalidPayload }; return value }
        func flag(_ key: String) throws -> Bool { guard case .flag(let value) = fields[key]?.value else { throw SyncRecoveryError.invalidPayload }; return value }
        document.title = try text("title"); document.summary = try text("summary")
        document.correspondent = try text("correspondent"); document.tags = try text("tags"); document.entities = try text("entities")
        document.favorite = try flag("favorite"); document.needsReview = try flag("review")
        guard case .date(let date) = fields["documentDate"]?.value else { throw SyncRecoveryError.invalidPayload }
        document.documentDate = date
        switch fields["trashedAt"]?.value {
        case .date(let date): document.trashedAt = date
        case .null: document.trashedAt = nil
        default: throw SyncRecoveryError.invalidPayload
        }
        document.collections = []
        for (key, field) in fields where key.hasPrefix("membership:") && field.value == .flag(true) {
            guard let id = UUID(uuidString: String(key.dropFirst(11))) else { throw SyncRecoveryError.invalidPayload }
            let query = FetchDescriptor<ArchiveSchemaV5.CollectionIdentity>(predicate: #Predicate { $0.id == id })
            guard let collection = try context.fetch(query).first else { throw SyncRecoveryError.unsupportedRecord }
            document.collections.insert(collection.name)
        }
        let id = old.id
        guard let record = try context.fetch(FetchDescriptor<Record>(predicate: #Predicate { $0.id == id })).first else { throw ArchiveError.missingRecord }
        if document != old { document.modifiedAt = Date(); record.updateMetadata(from: document); markSearchChanged(id) }
        let analysis: Analysis
        if let existing = try self.analysis(id) { analysis = existing }
        else { analysis = Analysis(id); context.insert(analysis) }
        var protected = Set(analysis.protectedFields)
        for (key, field) in fields where field.manual {
            if key.hasPrefix("membership:") { protected.insert("collections") }
            else if UnderstandingPolicy.fields.contains(key) { protected.insert(key) }
        }
        analysis.protectedFields = protected.sorted()
        // Invalidate an in-flight analysis so remote metadata cannot be overwritten by stale work.
        analysis.revision += 1
        if analysis.state == "analyzing" { analysis.state = "queued" }
        if document.trashedAt != nil && ["queued", "waitingText"].contains(analysis.state) { analysis.state = "paused" }
        else if document.trashedAt == nil && analysis.state == "paused" {
            analysis.state = try processingJob(id)?.state == "complete" ? "queued" : "waitingText"
        }
        if let job = try processingJob(id) {
            if document.trashedAt != nil && (job.snapshot.state.isActive || job.state == "queued") { job.state = "paused" }
            else if document.trashedAt == nil && job.state == "paused" { job.state = "queued" }
        }
    }

    func openConflictRecords(_ key: String? = nil) throws -> [Conflict] {
        let open = "open"
        if let key {
            return try context.fetch(FetchDescriptor<Conflict>(predicate: #Predicate { $0.status == open && $0.recordKey == key }))
        }
        return try context.fetch(FetchDescriptor<Conflict>(predicate: #Predicate { $0.status == open }))
    }

    func syncConflicts(includeHistory: Bool = false) throws -> [StoredSyncConflict] {
        let rows = try includeHistory ? context.fetch(FetchDescriptor<Conflict>()) : openConflictRecords()
        return try rows.map { StoredSyncConflict(id: $0.id, recordKey: $0.recordKey,
            conflict: try JSONDecoder().decode(SyncConflict.self, from: $0.payload), status: $0.status) }
    }

    func resolveSyncConflict(_ id: UUID, choosing choice: SyncConflictChoice) throws {
        do {
            guard let conflict = try context.fetch(FetchDescriptor<Conflict>(predicate: #Predicate { $0.id == id })).first,
                  conflict.status == "open", let row = try syncRecord(conflict.recordKey) else { throw SyncRecoveryError.staleConflict }
            var metadata = try JSONDecoder().decode(SyncMetadata.self, from: row.payload)
            let observed = try JSONDecoder().decode(SyncField.self, from: conflict.observedField)
            guard metadata.fields[conflict.field] == observed else { throw SyncRecoveryError.staleConflict }
            let alternatives = try JSONDecoder().decode(SyncConflict.self, from: conflict.payload)
            let selected = choice == .local ? alternatives.local : alternatives.server
            metadata.fields[conflict.field] = SyncField(value: selected.value, manual: true, operationID: UUID())
            guard let docID = UUID(uuidString: String(metadata.recordKey.dropFirst(9))), let document = try document(docID) else { throw ArchiveError.missingRecord }
            try materialize(metadata, document: document)
            row.payload = try JSONEncoder().encode(metadata); row.operationID = UUID(); row.pending = true; row.changedAt = Date()
            conflict.status = "resolved"
            for other in try openConflictRecords(conflict.recordKey) where other.field == conflict.field { other.status = "superseded" }
            try save()
        } catch { context.rollback(); throw error }
    }
}
