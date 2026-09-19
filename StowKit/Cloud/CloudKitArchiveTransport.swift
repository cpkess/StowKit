import Foundation
import CloudKit
import CryptoKit

struct OriginalManifest: Codable, Sendable {
    var version = 1
    let hash: String
    let size: Int64
    let chunks: [String]
    static let chunkSize = 8 * 1024 * 1024
}

enum CloudArchiveError: LocalizedError, Equatable {
    case setupRequired, accountChanged, unavailable, corruptAsset, missingResult, unsupportedDeletion, largeManifest
    var errorDescription: String? {
        switch self {
        case .setupRequired: "This build needs an Apple Developer signing team and an iCloud container. See the iCloud setup guide in the repository."
        case .accountChanged: "The iCloud account changed. Sync is paused to keep this archive separate from the new account."
        case .unavailable: "Sign in to iCloud in System Settings, then try again."
        case .corruptAsset: "The iCloud original failed verification. Your local recovery files have been kept."
        case .missingResult: "iCloud did not return a complete result. Sync will retry without discarding pending changes."
        case .unsupportedDeletion: "Records were removed from this iCloud archive outside StowKit. Sync is paused; local copies have been preserved."
        case .largeManifest: "This original exceeds the supported iCloud transfer size. It remains safely stored on this Mac."
        }
    }
}

actor CloudKitArchiveTransport: ArchiveCloudTransport {
    let binding: CloudArchiveBinding
    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    static let metadataKeys = ["metadata", "operationID", "textHead"]
    init(binding: CloudArchiveBinding) {
        self.binding = binding
        container = CKContainer(identifier: binding.containerID)
        database = binding.shared ? container.sharedCloudDatabase : container.privateCloudDatabase
        zoneID = CKRecordZone.ID(zoneName: binding.zoneName, ownerName: binding.ownerName)
    }
    func verifyAccount() async throws {
        guard try await container.accountStatus() == .available else { throw CloudArchiveError.unavailable }
        guard try await container.userRecordID().recordName == binding.accountID else { throw CloudArchiveError.accountChanged }
        try Task.checkCancellation()
    }
    func canWrite() async throws -> Bool {
        try await verifyAccount()
        if !binding.shared { return true }
        let record = try await fetchRecord(recordID(CKRecordNameZoneWideShare), keys: [])
        guard let share = record as? CKShare, let participant = share.currentUserParticipant else { throw CloudArchiveError.unavailable }
        return participant.permission == .readWrite
    }
    private func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }
    static func systemFields(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder); coder.finishEncoding()
        return coder.encodedData
    }
    private func restore(_ data: Data) throws -> CKRecord {
        let coder = try NSKeyedUnarchiver(forReadingFrom: data); coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        guard let record = CKRecord(coder: coder), record.recordID.zoneID == zoneID else { throw SyncRecoveryError.invalidPayload }
        return record
    }
    private func snapshot(_ record: CKRecord) throws -> CloudRecordSnapshot {
        guard record.recordType == "StowMetadata", let payload = record.encryptedValues["metadata"] as? Data,
              payload.count <= 1_048_576 else { throw SyncRecoveryError.invalidPayload }
        let metadata = try JSONDecoder().decode(SyncMetadata.self, from: payload)
        guard metadata.archiveID == binding.archiveID, metadata.recordKey == record.recordID.recordName else { throw SyncRecoveryError.invalidPayload }
        return CloudRecordSnapshot(metadata: metadata, systemFields: Self.systemFields(record))
    }
    func fetchChanges(after token: String) async throws -> CloudChangePage {
        try await verifyAccount()
        let previous: CKServerChangeToken?
        if token.isEmpty { previous = nil }
        else {
            guard let data = Data(base64Encoded: token),
                  let value = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data) else { throw SyncRecoveryError.invalidPayload }
            previous = value
        }
        let result = try await database.recordZoneChanges(inZoneWith: zoneID, since: previous,
            desiredKeys: Self.metadataKeys, resultsLimit: 64)
        guard result.deletions.isEmpty else { throw CloudArchiveError.unsupportedDeletion }
        var records: [CloudRecordSnapshot] = []
        var textHeads: [CloudTextHead] = []
        for (_, modification) in result.modificationResultsByID {
            let record = try modification.get().record
            if record.recordType == "StowMetadata" { records.append(try snapshot(record)) }
            if record.recordType == "StowText", let data = record.encryptedValues["textHead"] as? Data {
                guard data.count < 4096 else { throw SyncRecoveryError.invalidPayload }
                textHeads.append(try JSONDecoder().decode(CloudTextHead.self, from: data))
            }
        }
        let data = try NSKeyedArchiver.archivedData(withRootObject: result.changeToken, requiringSecureCoding: true)
        return CloudChangePage(records: records, token: data.base64EncodedString(), moreComing: result.moreComing, textHeads: textHeads)
    }
    func save(_ request: CloudSaveRequest) async throws -> CloudSaveResult {
        try await verifyAccount()
        let operation = request.operation
        let record = try request.systemFields.map(restore) ?? CKRecord(recordType: "StowMetadata", recordID: recordID(operation.metadata.recordKey))
        guard record.recordID == recordID(operation.metadata.recordKey), operation.metadata.archiveID == binding.archiveID else { throw SyncRecoveryError.invalidPayload }
        let data = try JSONEncoder().encode(operation.metadata)
        guard data.count <= 900_000 else { throw SyncRecoveryError.invalidPayload }
        record.encryptedValues["metadata"] = data as NSData
        record.encryptedValues["operationID"] = operation.id.uuidString as NSString
        do {
            let saved = try await CloudRecordOperations.save(record, database: database)
            return CloudSaveResult(operationID: operation.id, saved: try snapshot(saved), conflict: nil)
        } catch {
            if let ck = error as? CKError, ck.code == .serverRecordChanged {
                let server: CKRecord
                if let value = ck.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord { server = value }
                else { server = try await fetchRecord(record.recordID, keys: Self.metadataKeys) }
                // A lost response followed by a retry can observe its own completed save.
                if server.encryptedValues["operationID"] as? String == operation.id.uuidString {
                    return CloudSaveResult(operationID: operation.id, saved: try snapshot(server), conflict: nil)
                }
                return CloudSaveResult(operationID: operation.id, saved: nil, conflict: try snapshot(server))
            }
            throw error
        }
    }
    private func fetchRecord(_ id: CKRecord.ID, keys: [String]) async throws -> CKRecord {
        let results = try await database.records(for: [id], desiredKeys: keys)
        guard let result = results[id] else { throw CloudArchiveError.missingResult }
        return try result.get()
    }
    private func existingRecord(_ id: CKRecord.ID, keys: [String]) async throws -> CKRecord? {
        do { return try await fetchRecord(id, keys: keys) }
        catch let error as CKError where error.code == .unknownItem { return nil }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func uploadOriginal(_ document: HouseholdDocument, url: URL) async throws {
        try await verifyAccount()
        guard document.fileSize > 0, document.fileSize <= Int64(OriginalManifest.chunkSize) * 8192 else { throw CloudArchiveError.largeManifest }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("StowKitCloudUpload-\(UUID())")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        var hashes: [String] = [], size: Int64 = 0, hasher = SHA256()
        while let data = try input.read(upToCount: OriginalManifest.chunkSize), !data.isEmpty {
            try await verifyAccount()
            let hash = Self.digest(data), index = hashes.count
            size += Int64(data.count); hasher.update(data: data)
            guard size <= document.fileSize else { throw CloudArchiveError.corruptAsset }
            let id = recordID("chunk:\(document.contentHash):\(index)")
            if let existing = try await existingRecord(id, keys: ["digest"]) {
                guard existing.encryptedValues["digest"] as? String == hash else { throw CloudArchiveError.corruptAsset }
            } else {
                let file = staging.appendingPathComponent("chunk")
                try data.write(to: file, options: .atomic)
                let record = CKRecord(recordType: "StowChunk", recordID: id)
                record.encryptedValues["digest"] = hash as NSString
                record["asset"] = CKAsset(fileURL: file)
                do {
                    _ = try await CloudRecordOperations.save(record, database: database)
                } catch let error as CKError where error.code == .serverRecordChanged {
                    let existing = try await fetchRecord(id, keys: ["digest"])
                    guard existing.encryptedValues["digest"] as? String == hash else { throw CloudArchiveError.corruptAsset }
                }
            }
            hashes.append(hash)
        }
        guard size == document.fileSize, hasher.finalize().map({ String(format: "%02x", $0) }).joined() == document.contentHash else { throw CloudArchiveError.corruptAsset }
        let manifest = OriginalManifest(hash: document.contentHash, size: size, chunks: hashes)
        let data = try JSONEncoder().encode(manifest), id = recordID("original:\(document.contentHash)")
        if let existing = try await existingRecord(id, keys: ["manifest"]) {
            guard let old = existing.encryptedValues["manifest"] as? Data,
                  try JSONDecoder().decode(OriginalManifest.self, from: old).chunks == hashes else { throw CloudArchiveError.corruptAsset }
            return
        }
        let record = CKRecord(recordType: "StowOriginal", recordID: id); record.encryptedValues["manifest"] = data as NSData
        do {
            _ = try await CloudRecordOperations.save(record, database: database)
        } catch let error as CKError where error.code == .serverRecordChanged {
            let existing = try await fetchRecord(id, keys: ["manifest"])
            guard let data = existing.encryptedValues["manifest"] as? Data,
                  try JSONDecoder().decode(OriginalManifest.self, from: data).chunks == hashes else { throw CloudArchiveError.corruptAsset }
        }
    }
    func uploadText(_ document: HouseholdDocument, pages: [CloudTextPage]) async throws {
        let data = try JSONEncoder().encode(pages)
        guard data.count <= 64 * 1024 * 1024 else { throw CloudArchiveError.largeManifest }
        let head = CloudTextHead(originalHash: document.contentHash, blobHash: Self.digest(data), size: Int64(data.count))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("StowKitText-\(UUID())")
        try data.write(to: file, options: .atomic); defer { try? FileManager.default.removeItem(at: file) }
        try await uploadOriginal(head.blobDocument(archiveID: binding.archiveID), url: file)
        let id = recordID("text:\(document.contentHash)")
        let record = try await existingRecord(id, keys: ["textHead"]) ?? CKRecord(recordType: "StowText", recordID: id)
        record.encryptedValues["textHead"] = try JSONEncoder().encode(head) as NSData
        _ = try await CloudRecordOperations.save(record, database: database)
    }
    func downloadText(_ head: CloudTextHead) async throws -> [CloudTextPage] {
        guard head.version == 1, head.size > 0, head.size <= 64 * 1024 * 1024 else { throw SyncRecoveryError.invalidPayload }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StowKitTextDownload-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("text")
        try await downloadOriginal(head.blobDocument(archiveID: binding.archiveID), to: file)
        let pages = try JSONDecoder().decode([CloudTextPage].self, from: Data(contentsOf: file))
        guard pages.count <= 100_000, pages.enumerated().allSatisfy({ $0.offset == $0.element.index }) else { throw SyncRecoveryError.invalidPayload }
        return pages
    }
    func downloadOriginal(_ document: HouseholdDocument, to url: URL) async throws {
        try await verifyAccount()
        let record = try await fetchRecord(recordID("original:\(document.contentHash)"), keys: ["manifest"])
        guard let data = record.encryptedValues["manifest"] as? Data, data.count < 900_000 else { throw CloudArchiveError.corruptAsset }
        let manifest = try JSONDecoder().decode(OriginalManifest.self, from: data)
        guard manifest.version == 1, manifest.hash == document.contentHash, manifest.size == document.fileSize,
              manifest.size > 0, manifest.size <= Int64(OriginalManifest.chunkSize) * 8192, manifest.chunks.count <= 8192,
              manifest.chunks.count == Int((manifest.size + Int64(OriginalManifest.chunkSize) - 1) / Int64(OriginalManifest.chunkSize)) else { throw CloudArchiveError.corruptAsset }
        let parts = url.appendingPathExtension("parts")
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        for (index, hash) in manifest.chunks.enumerated() {
            try await verifyAccount()
            let local = parts.appendingPathComponent(String(index))
            if let cached = try? Data(contentsOf: local), Self.digest(cached) == hash { continue }
            let chunk = try await fetchRecord(recordID("chunk:\(manifest.hash):\(index)"), keys: ["asset", "digest"])
            guard let asset = chunk["asset"] as? CKAsset, let source = asset.fileURL else { throw CloudArchiveError.corruptAsset }
            let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= OriginalManifest.chunkSize else { throw CloudArchiveError.corruptAsset }
            let bytes = try Data(contentsOf: source)
            guard Self.digest(bytes) == hash else { throw CloudArchiveError.corruptAsset }
            try bytes.write(to: local, options: .atomic)
        }
        try await verifyAccount()
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url); defer { try? output.close() }
        try output.truncate(atOffset: 0)
        var hasher = SHA256(), total: Int64 = 0
        for index in manifest.chunks.indices {
            try Task.checkCancellation()
            let data = try Data(contentsOf: parts.appendingPathComponent(String(index)))
            total += Int64(data.count); hasher.update(data: data); try output.write(contentsOf: data)
        }
        try output.synchronize()
        guard total == manifest.size, hasher.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.hash else { throw CloudArchiveError.corruptAsset }
        try FileManager.default.removeItem(at: parts)
    }
}
