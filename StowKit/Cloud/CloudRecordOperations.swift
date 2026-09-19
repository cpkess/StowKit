import Foundation
import CloudKit

enum CloudRecordOperations {
    static func recordError(_ error: Error, id: CKRecord.ID) -> Error {
        guard let cloud = error as? CKError, cloud.code == .partialFailure,
              let errors = cloud.partialErrorsByItemID, let nested = errors[id] else { return error }
        return nested
    }
    static func save(_ record: CKRecord, database: CKDatabase) async throws -> CKRecord {
        do {
            let response = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
            guard let result = response.saveResults[record.recordID] else { throw CloudArchiveError.missingResult }
            return try result.get()
        } catch { throw recordError(error, id: record.recordID) }
    }
}
