import Foundation
import SwiftData
import UniformTypeIdentifiers

extension ArchiveRepository {
    typealias CloudCollection = ArchiveSchemaV7.Collection
    typealias Membership = ArchiveSchemaV7.Membership
    typealias CloudState = ArchiveSchemaV7.CloudState

    func normalizedCollection(_ id: UUID) throws -> CloudCollection? {
        try context.fetch(FetchDescriptor<CloudCollection>(predicate: #Predicate { $0.id == id })).first
    }
    func ensureNormalizedCollection(_ collection: LibraryCollection, id: UUID) throws -> CloudCollection {
        if let existing = try normalizedCollection(id) { return existing }
        let record = CloudCollection(id: id, name: collection.name, symbol: collection.symbol, localName: collection.name)
        context.insert(record); return record
    }
    func saveMemberships(_ metadata: SyncMetadata, documentID: UUID) throws {
        for (field, value) in metadata.fields where field.hasPrefix("membership:") {
            guard let id = UUID(uuidString: String(field.dropFirst(11))), case .flag(let active) = value.value else { throw SyncRecoveryError.invalidPayload }
            let key = "\(documentID):\(id)"
            if let existing = try context.fetch(FetchDescriptor<Membership>(predicate: #Predicate { $0.key == key })).first { existing.active = active }
            else { context.insert(Membership(documentID: documentID, collectionID: id, active: active)) }
        }
    }
    func applyIncomingCollection(_ remote: SyncMetadata) throws {
        guard remote.archiveID == archiveID, remote.formatVersion == 1,
              let id = UUID(uuidString: String(remote.recordKey.dropFirst(11))),
              case .text(let name) = remote.fields["name"]?.value,
              case .text(let symbol) = remote.fields["symbol"]?.value,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 512,
              symbol.utf8.count <= 128, Set(remote.fields.keys) == ["name", "symbol"] else { throw SyncRecoveryError.invalidPayload }
        let normalized: CloudCollection
        if let existing = try normalizedCollection(id) { normalized = existing }
        else {
            var localName = name
            let used = Set(try collections().map(\.name))
            if used.contains(localName) { localName = "\(name) (\(id.uuidString))" }
            normalized = CloudCollection(id: id, name: name, symbol: symbol, localName: localName)
            context.insert(normalized)
            let identity = ArchiveSchemaV5.CollectionIdentity(name: localName); identity.id = id
            context.insert(identity)
            context.insert(ArchiveSchemaV1.CollectionRecord(.init(name: localName, symbol: symbol)))
        }
        let row = try syncRecord(remote.recordKey)
        let local = try row.map { try JSONDecoder().decode(SyncMetadata.self, from: $0.payload) }
        let oldBaseline = try serverBaseline(remote.recordKey)
        let base = try oldBaseline.map { try JSONDecoder().decode(SyncMetadata.self, from: $0.payload) }
        let merge = SyncMergePolicy.merge(base: base?.fields ?? [:], local: local?.fields ?? remote.fields, server: remote.fields)
        // Collection labels are currently creation-only in the UI. Preserve conflicting labels
        // as separate identities; canonical rename follows the server while local aliases remain stable.
        if case .text(let value) = merge.fields["name"]?.value { normalized.name = value }
        if case .text(let value) = merge.fields["symbol"]?.value { normalized.symbol = value }
        let metadata = SyncMetadata(archiveID: archiveID, recordKey: remote.recordKey, fields: merge.fields)
        let payload = try JSONEncoder().encode(metadata)
        if let row { row.payload = payload; row.pending = metadata != remote; row.operationID = UUID() }
        else { let inserted = SyncRecord(key: remote.recordKey, operationID: UUID(), payload: payload); inserted.pending = false; context.insert(inserted) }
        let encoded = try JSONEncoder().encode(remote)
        if let oldBaseline { oldBaseline.payload = encoded }
        else { context.insert(Baseline(key: remote.recordKey, payload: encoded)) }
    }

    func cloudState(_ key: String) throws -> CloudState? {
        try context.fetch(FetchDescriptor<CloudState>(predicate: #Predicate { $0.key == key })).first
    }
    func cloudRequest(_ operation: SyncOperation) throws -> CloudSaveRequest {
        var metadata = operation.metadata
        let state = try cloudState(metadata.recordKey)
        if metadata.recordKey.hasPrefix("document:"), case .text(let hash) = metadata.fields["contentHash"]?.value {
            let id = CloudDocumentIdentity.id(archive: archiveID, hash: hash)
            metadata = SyncMetadata(archiveID: archiveID, recordKey: "document:\(id)", fields: metadata.fields)
            metadata.fields["id"]?.value = .text(id.uuidString)
            if let state, !operation.metadata.isTombstone {
                let original = try JSONDecoder().decode(SyncMetadata.self, from: state.wireMetadata)
                for key in ["originalFilename", "importedAt"] { metadata.fields[key] = original.fields[key] }
            }
        }
        return CloudSaveRequest(operation: SyncOperation(id: operation.id, metadata: metadata), systemFields: state?.systemFields)
    }

    func localizeCloudRecord(_ wire: SyncMetadata) throws -> SyncMetadata {
        guard wire.archiveID == archiveID, wire.formatVersion == 1 else { throw SyncRecoveryError.invalidPayload }
        guard wire.recordKey.hasPrefix("document:") else { return wire }
        guard case .text(let hash) = wire.fields["contentHash"]?.value,
              hash.count == 64, hash == hash.lowercased(), hash.allSatisfy({ $0.isHexDigit }),
              case .text(let identity) = wire.fields["id"]?.value,
              identity == CloudDocumentIdentity.id(archive: archiveID, hash: hash).uuidString,
              wire.recordKey == "document:\(identity)",
              case .integer(let size) = wire.fields["fileSize"]?.value, size > 0, size <= Int64(OriginalManifest.chunkSize) * 8192,
              case .text(let type) = wire.fields["contentType"]?.value,
              ["com.adobe.pdf", "public.jpeg", "public.png", "public.heic"].contains(type),
              case .text(let filename) = wire.fields["originalFilename"]?.value,
              filename.utf8.count <= 1024,
              case .date(let imported) = wire.fields["importedAt"]?.value else { throw SyncRecoveryError.invalidPayload }
        var local = wire
        let document: HouseholdDocument
        if let existing = try matching(hash: hash) {
            guard existing.fileSize == size, existing.contentType == type else { throw SyncRecoveryError.invalidPayload }
            document = existing
        } else {
            guard let id = UUID(uuidString: identity), let ext = UTType(type)?.preferredFilenameExtension else { throw SyncRecoveryError.invalidPayload }
            document = HouseholdDocument(id: id, archiveID: archiveID, title: filename, originalFilename: filename,
                documentDate: imported, importedAt: imported, modifiedAt: imported,
                contentType: type, contentHash: hash, fileSize: size, relativePath: "Originals/\(identity.prefix(2))/\(identity).\(ext)")
            context.insert(Record(document))
            let job = Job(documentID: id); job.state = "remote"; context.insert(job)
            context.insert(Analysis(id, state: "remote"))
            context.insert(ArchiveSchemaV7.OriginalState(documentID: id, remote: true))
            // First remote observation is its own local starting point, never a competing import.
            let payload = try JSONEncoder().encode(wire)
            let journal = SyncRecord(key: wire.recordKey, operationID: UUID(), payload: payload); journal.pending = false
            context.insert(journal)
            markSearchChanged(id)
        }
        local = SyncMetadata(archiveID: archiveID, recordKey: "document:\(document.id)", fields: wire.fields)
        local.fields["id"]?.value = .text(document.id.uuidString)
        local.fields["originalFilename"]?.value = .text(document.originalFilename)
        local.fields["importedAt"]?.value = .date(document.importedAt)
        return local
    }
    func storeCloudState(_ record: CloudRecordSnapshot, key: String) throws {
        let encoded = try JSONEncoder().encode(record.metadata)
        if let state = try cloudState(key) { state.systemFields = record.systemFields; state.wireMetadata = encoded }
        else { context.insert(CloudState(key: key, systemFields: record.systemFields, wireMetadata: encoded)) }
    }
    func applyCloudPage(_ page: CloudChangePage, after token: String) throws {
        do {
            let ordered = page.records.sorted { $0.metadata.recordKey.hasPrefix("collection:") && !$1.metadata.recordKey.hasPrefix("collection:") }
            var localized: [SyncMetadata] = []
            for record in ordered {
                if record.metadata.isTombstone { try applyIncomingTombstone(record.metadata); continue }
                let metadata = try localizeCloudRecord(record.metadata)
                localized.append(metadata)
                try storeCloudState(record, key: metadata.recordKey)
            }
            for head in page.textHeads { try queueTextDownload(head) }
            try applyIncomingPage(.init(previousToken: token, nextToken: page.token, records: localized))
        } catch { context.rollback(); throw error }
    }
    func acceptCloudSave(_ result: CloudSaveResult, sent: SyncOperation) throws {
        do {
            guard result.operationID == sent.id, (result.saved == nil) != (result.conflict == nil) else { throw CloudArchiveError.missingResult }
            let expected = try cloudRequest(sent).operation.metadata
            guard let returned = result.saved ?? result.conflict,
                  returned.metadata.archiveID == expected.archiveID,
                  returned.metadata.recordKey == expected.recordKey else { throw SyncRecoveryError.invalidPayload }
            if let saved = result.saved {
                try storeCloudState(saved, key: sent.metadata.recordKey)
                let data = try JSONEncoder().encode(sent.metadata)
                if let baseline = try serverBaseline(sent.metadata.recordKey) { baseline.payload = data }
                else { context.insert(Baseline(key: sent.metadata.recordKey, payload: data)) }
                try acknowledgeSyncOperations([sent.id])
                tombstoneAccepted(sent.metadata)
            } else if let conflict = result.conflict, conflict.metadata.isTombstone {
                // Already deleted in iCloud, possibly by our own save whose response was lost.
                try applyIncomingTombstone(conflict.metadata)
                tombstoneAccepted(conflict.metadata)
                try save()
            } else if let conflict = result.conflict, sent.metadata.isTombstone {
                // Someone edited it concurrently. Keep the newer change tag and resend: delete wins,
                // rather than recreating a document the owner just deleted permanently.
                try storeCloudState(conflict, key: sent.metadata.recordKey)
                try save()
            } else if let conflict = result.conflict {
                let local = try localizeCloudRecord(conflict.metadata)
                try storeCloudState(conflict, key: local.recordKey)
                if local.recordKey.hasPrefix("collection:") { try applyIncomingCollection(local) }
                else { try applyIncoming(local) }
                try save()
            }
        } catch { context.rollback(); throw error }
    }
}
