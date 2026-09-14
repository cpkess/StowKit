import Foundation
import SwiftData

enum ArchiveSchemaV6: VersionedSchema {
    static var versionIdentifier = Schema.Version(6, 0, 0)
    static var models: [any PersistentModel.Type] {
        ArchiveSchemaV5.models + [SyncCheckpoint.self, ServerBaseline.self, ConflictRecord.self]
    }
    @Model final class SyncCheckpoint {
        @Attribute(.unique) var key: String
        var value: String
        init(_ key: String, value: String = "") { self.key = key; self.value = value }
    }
    @Model final class ServerBaseline {
        @Attribute(.unique) var key: String
        var payload: Data
        init(key: String, payload: Data) { self.key = key; self.payload = payload }
    }
    @Model final class ConflictRecord {
        @Attribute(.unique) var id: UUID
        var recordKey: String
        var field: String
        var payload: Data
        var observedField: Data
        var status: String
        init(recordKey: String, conflict: SyncConflict, payload: Data, observedField: Data) {
            id = UUID(); self.recordKey = recordKey; field = conflict.field
            self.payload = payload; self.observedField = observedField; status = "open"
        }
    }
}
