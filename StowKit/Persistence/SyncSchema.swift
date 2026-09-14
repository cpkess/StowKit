import Foundation
import SwiftData

/// Additive local-only schema. Prior models remain frozen; CloudKit stays disabled.
enum ArchiveSchemaV5: VersionedSchema {
    static var versionIdentifier = Schema.Version(5, 0, 0)
    static var models: [any PersistentModel.Type] {
        ArchiveSchemaV4.models + [SyncRecord.self, CollectionIdentity.self]
    }
    /// Latest snapshot doubles as a coalesced outbox. Field stamps survive acknowledgments.
    @Model final class SyncRecord {
        @Attribute(.unique) var key: String
        var operationID: UUID
        var payload: Data
        var pending: Bool
        var changedAt: Date
        init(key: String, operationID: UUID, payload: Data) {
            self.key = key; self.operationID = operationID; self.payload = payload
            pending = true; changedAt = Date()
        }
    }
    /// Bridges the frozen name-based local schema to stable sync identities.
    /// Full collection normalization/renaming is deliberately not introduced here.
    @Model final class CollectionIdentity {
        @Attribute(.unique) var name: String
        var id: UUID
        init(name: String) { self.name = name; id = UUID() }
    }
}
