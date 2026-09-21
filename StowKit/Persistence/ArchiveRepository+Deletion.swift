import Foundation
import SwiftData

/// Permanent deletion. Moving to Trash stays the recoverable step; this is the only path that
/// removes a document everywhere. Local rows go in one transaction with a content-free tombstone
/// (`journalTombstone`); files and iCloud content are cleaned up afterwards from durable lists
/// kept in the checkpoint table, so a crash between steps leaves work to finish, never orphans.
extension ArchiveRepository {
    enum DeletionError: LocalizedError {
        case notInTrash
        var errorDescription: String? { "Only documents in Trash can be deleted permanently." }
    }
    private static let filePurge = "purge-files:"
    private static let cloudPurge = "purge-cloud:"

    /// Delete documents that are in Trash, here and — once synced — from iCloud and every Mac.
    func permanentlyDelete(_ ids: [UUID]) throws {
        do {
            for id in ids {
                guard let document = try document(id) else { continue }
                guard document.trashedAt != nil else { throw DeletionError.notInTrash }
                let textEmpty = (try processingJob(id)?.snapshot.characterCount ?? 0) == 0
                try journalTombstone(documentID: id, contentHash: document.contentHash)
                try removeLocalRecords(document)
                // Waits for the tombstone to reach iCloud before its content is deleted there.
                setCheckpoint(Self.cloudPurge + document.contentHash, "waiting|" + (textEmpty ? "keep-text" : "text"))
            }
            try save()
        } catch { context.rollback(); throw error }
    }

    /// A tombstone arrived from iCloud: remove this Mac's copy and drop any unsent edits to it.
    /// Throws when the payload is not a well-formed tombstone for this archive.
    func applyIncomingTombstone(_ wire: SyncMetadata) throws {
        guard wire.archiveID == archiveID, case .text(let hash) = wire.fields["contentHash"]?.value,
              hash.count == 64, hash.allSatisfy(\.isHexDigit),
              case .text(let identity) = wire.fields["id"]?.value,
              identity == CloudDocumentIdentity.id(archive: archiveID, hash: hash).uuidString,
              wire.recordKey == "document:\(identity)" else { throw SyncRecoveryError.invalidPayload }
        guard let document = try matching(hash: hash) else { return }
        let key = "document:\(document.id.uuidString)"
        try removeLocalRecords(document)
        // Replace any pending local edit with the tombstone and mark it sent: the deletion wins.
        let payload = try JSONEncoder().encode(SyncMetadata(archiveID: archiveID, recordKey: key, fields: wire.fields))
        if let record = try syncRecord(key) { record.payload = payload; record.pending = false }
        else { let record = SyncRecord(key: key, operationID: UUID(), payload: payload); record.pending = false; context.insert(record) }
        for conflict in try openConflictRecords(key) { conflict.status = "superseded" }
    }

    /// Called once iCloud has accepted a tombstone, making its content safe to delete there.
    func tombstoneAccepted(_ metadata: SyncMetadata) {
        guard metadata.isTombstone, case .text(let hash) = metadata.fields["contentHash"]?.value,
              let value = checkpointValue(Self.cloudPurge + hash), value.hasPrefix("waiting|") else { return }
        setCheckpoint(Self.cloudPurge + hash, "ready|" + value.dropFirst("waiting|".count))
    }
    func pendingFilePurges() throws -> [(id: UUID, relativePath: String)] {
        try checkpoints(prefix: Self.filePurge).compactMap { key, value in
            UUID(uuidString: String(key.dropFirst(Self.filePurge.count))).map { ($0, value) }
        }
    }
    func pendingCloudPurges() throws -> [(hash: String, keepText: Bool)] {
        try checkpoints(prefix: Self.cloudPurge).compactMap { key, value in
            guard value.hasPrefix("ready|") else { return nil }
            return (String(key.dropFirst(Self.cloudPurge.count)), value.hasSuffix("keep-text"))
        }
    }
    func completeFilePurge(_ id: UUID) throws { try clearCheckpoint(Self.filePurge + id.uuidString) }
    func completeCloudPurge(_ hash: String) throws { try clearCheckpoint(Self.cloudPurge + hash) }

    private func removeLocalRecords(_ document: HouseholdDocument) throws {
        let id = document.id, hash = document.contentHash
        for record in try context.fetch(FetchDescriptor<Record>(predicate: #Predicate { $0.id == id })) { context.delete(record) }
        if let analysis = try analysis(id) { context.delete(analysis) }
        if let job = try processingJob(id) { context.delete(job) }
        for page in try context.fetch(FetchDescriptor<Page>(predicate: #Predicate { $0.documentID == id })) { context.delete(page) }
        if let state = try originalCloudState(id) { context.delete(state) }
        for row in try context.fetch(FetchDescriptor<ArchiveSchemaV7.Membership>(predicate: #Predicate { $0.documentID == id })) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<ArchiveSchemaV7.TextUpload>(predicate: #Predicate { $0.documentID == id })) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<ArchiveSchemaV8.TextDownload>(predicate: #Predicate { $0.sourceHash == hash })) { context.delete(row) }
        for conflict in try openConflictRecords("document:\(id.uuidString)") { conflict.status = "superseded" }
        markSearchChanged(id)
        setCheckpoint(Self.filePurge + id.uuidString, document.relativePath)
    }

    private func checkpointValue(_ key: String) -> String? {
        (try? context.fetch(FetchDescriptor<Checkpoint>(predicate: #Predicate { $0.key == key })).first)?.value
    }
    private func setCheckpoint(_ key: String, _ value: String) {
        if let row = try? context.fetch(FetchDescriptor<Checkpoint>(predicate: #Predicate { $0.key == key })).first { row.value = value }
        else { context.insert(Checkpoint(key, value: value)) }
    }
    private func clearCheckpoint(_ key: String) throws {
        for row in try context.fetch(FetchDescriptor<Checkpoint>(predicate: #Predicate { $0.key == key })) { context.delete(row) }
        try save()
    }
    private func checkpoints(prefix: String) throws -> [(String, String)] {
        try context.fetch(FetchDescriptor<Checkpoint>(predicate: #Predicate { $0.key.starts(with: prefix) }))
            .filter { !$0.value.isEmpty }.map { ($0.key, $0.value) }
    }
}
