import Foundation
import CryptoKit

struct CloudArchiveBinding: Codable, Equatable, Sendable {
    let containerID: String
    let environment: String
    let accountID: String
    let archiveID: UUID
    let zoneName: String
    let ownerName: String
    let shared: Bool
}

struct CloudRecordSnapshot: Sendable {
    let metadata: SyncMetadata
    let systemFields: Data
}
struct CloudChangePage: Sendable {
    let records: [CloudRecordSnapshot]
    let token: String
    let moreComing: Bool
    var textHeads: [CloudTextHead] = []
}
struct CloudSaveRequest: Sendable {
    let operation: SyncOperation
    let systemFields: Data?
}
struct CloudSaveResult: Sendable {
    let operationID: UUID
    let saved: CloudRecordSnapshot?
    let conflict: CloudRecordSnapshot?
}

/// Archive-scoped content identity makes concurrent exact imports target one conditional save.
/// Local document UUIDs and paths stay unchanged; each device translates at the transport boundary.
enum CloudDocumentIdentity {
    static func id(archive: UUID, hash: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("\(archive.uuidString):\(hash)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
}

protocol ArchiveCloudTransport: Sendable {
    func canWrite() async throws -> Bool
    func verifyAccount() async throws
    func fetchChanges(after token: String) async throws -> CloudChangePage
    func save(_ request: CloudSaveRequest) async throws -> CloudSaveResult
    func uploadOriginal(_ document: HouseholdDocument, url: URL) async throws
    func uploadText(_ document: HouseholdDocument, pages: [CloudTextPage]) async throws
    func downloadText(_ head: CloudTextHead) async throws -> [CloudTextPage]
    func downloadOriginal(_ document: HouseholdDocument, to url: URL) async throws
}

struct CloudTextHead: Codable, Sendable {
    var version = 1
    let originalHash: String
    let blobHash: String
    let size: Int64
    func blobDocument(archiveID: UUID) -> HouseholdDocument {
        let id = CloudDocumentIdentity.id(archive: archiveID, hash: blobHash), date = Date(timeIntervalSince1970: 0)
        return HouseholdDocument(id: id, archiveID: archiveID, title: "Text", originalFilename: "text.json", documentDate: date,
            importedAt: date, modifiedAt: date, contentType: "public.json", contentHash: blobHash, fileSize: size, relativePath: "")
    }
}
struct CloudTextPage: Codable, Sendable {
    let index: Int
    let text: String
    let method: ExtractionMethod
}
