import Foundation
import SwiftData

enum ArchiveSchemaV4: VersionedSchema {
    static var versionIdentifier = Schema.Version(4, 0, 0)
    static var models: [any PersistentModel.Type] { ArchiveSchemaV3.models + [AnalysisRecord.self] }
    @Model final class AnalysisRecord {
        @Attribute(.unique) var documentID: UUID
        var state: String
        var protectedFields: [String]
        var resultData: Data?
        var error: String?
        var updatedAt: Date
        var revision: Int
        init(_ id: UUID, state: String = "waitingText", protected: [String] = []) {
            documentID = id; self.state = state; protectedFields = protected
            updatedAt = Date(); revision = 0
        }
        var snapshot: AnalysisSnapshot {
            AnalysisSnapshot(id: documentID, state: state, result: resultData.flatMap { try? JSONDecoder().decode(DocumentUnderstanding.self, from: $0) }, error: error)
        }
    }
}
struct AnalysisSnapshot: Identifiable, Sendable {
    let id: UUID
    let state: String
    let result: DocumentUnderstanding?
    let error: String?
}
