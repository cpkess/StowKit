import Foundation

/// Local wire-format draft. No filesystem paths, jobs, OCR text, or model prompts.
struct SyncMetadata: Codable, Equatable, Sendable {
    var formatVersion = 1
    let archiveID: UUID
    let recordKey: String
    var fields: [String: SyncField]
}

struct SyncField: Codable, Equatable, Sendable {
    var value: SyncValue
    var manual: Bool
    let operationID: UUID
    var algorithmVersion: Int = 1
}

enum SyncValue: Codable, Equatable, Sendable {
    case text(String), flag(Bool), date(Date), integer(Int64), null
}

struct SyncOperation: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let metadata: SyncMetadata
}

struct SyncConflict: Codable, Equatable, Sendable {
    let field: String
    let local: SyncField
    let server: SyncField
}

struct SyncMerge: Sendable {
    let fields: [String: SyncField]
    let conflicts: [SyncConflict]
}

/// Three-way policy shared by local incoming application and conflict tests.
enum SyncMergePolicy {
    static func merge(base: [String: SyncField], local: [String: SyncField],
                      server: [String: SyncField]) -> SyncMerge {
        var result: [String: SyncField] = [:]
        var conflicts: [SyncConflict] = []
        for key in Set(base.keys).union(local.keys).union(server.keys).sorted() {
            // Absence means no observation; removals must be explicit values/tombstones.
            guard let lhs = local[key] else { result[key] = server[key]; continue }
            guard let rhs = server[key] else { result[key] = lhs; continue }
            if lhs == rhs { result[key] = lhs; continue }
            if lhs.value == rhs.value {
                var selected = preferred(lhs, rhs)
                selected.manual = lhs.manual || rhs.manual
                result[key] = selected
            } else if lhs.manual != rhs.manual {
                result[key] = lhs.manual ? lhs : rhs
            } else if lhs == base[key] { result[key] = rhs }
            else if rhs == base[key] { result[key] = lhs }
            else if key == "trashedAt", lhs.value == .null || rhs.value == .null {
                result[key] = lhs.value == .null ? rhs : lhs
            } else if key.hasPrefix("membership:"), lhs.value == .flag(false) || rhs.value == .flag(false) {
                result[key] = lhs.value == .flag(false) ? lhs : rhs
            } else if lhs.manual {
                result[key] = rhs
                conflicts.append(SyncConflict(field: key, local: lhs, server: rhs))
            } else { result[key] = preferred(lhs, rhs) }
        }
        return SyncMerge(fields: result, conflicts: conflicts)
    }

    private static func preferred(_ lhs: SyncField, _ rhs: SyncField) -> SyncField {
        if lhs.algorithmVersion != rhs.algorithmVersion {
            return lhs.algorithmVersion > rhs.algorithmVersion ? lhs : rhs
        }
        return lhs.operationID.uuidString > rhs.operationID.uuidString ? lhs : rhs
    }
}

/// The application never constructs a transport in this release. Tests inject a fake.
protocol MetadataSyncTransport: Sendable {
    func send(_ operations: [SyncOperation]) async throws -> Set<UUID>
}

@MainActor final class LocalSyncDriver {
    private let repository: ArchiveRepository
    private let transport: any MetadataSyncTransport
    private var sending = false
    init(repository: ArchiveRepository, transport: any MetadataSyncTransport) {
        self.repository = repository; self.transport = transport
    }
    /// One bounded attempt. A failure leaves all unacknowledged work durable for retry.
    func sendBatch(limit: Int = 64) async throws {
        guard !sending else { return }
        sending = true
        defer { sending = false }
        let batch = try repository.pendingSyncOperations(limit: limit)
        guard !batch.isEmpty else { return }
        let accepted = try await transport.send(batch)
        // A buggy transport cannot acknowledge records it wasn't sent.
        try repository.acknowledgeSyncOperations(accepted.intersection(Set(batch.map(\.id))))
    }
}
