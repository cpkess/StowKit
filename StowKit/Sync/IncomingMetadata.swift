import Foundation

/// One ordered, complete metadata page for the current local archive.
/// Tokens are opaque. The future CloudKit adapter must serialize its own zone feeds.
struct IncomingMetadataPage: Sendable {
    let previousToken: String
    let nextToken: String
    let records: [SyncMetadata]
}

protocol IncomingMetadataTransport: Sendable {
    func fetch(after token: String) async throws -> IncomingMetadataPage?
}

@MainActor final class LocalSyncReceiver {
    private let repository: ArchiveRepository
    private let transport: any IncomingMetadataTransport
    private var receiving = false
    init(repository: ArchiveRepository, transport: any IncomingMetadataTransport) {
        self.repository = repository; self.transport = transport
    }
    func receivePage() async throws {
        guard !receiving else { return }
        receiving = true
        defer { receiving = false }
        let token = try repository.incomingSyncToken()
        if let page = try await transport.fetch(after: token) {
            try repository.applyIncomingPage(page)
        }
    }
}

struct StoredSyncConflict: Identifiable, Sendable {
    let id: UUID
    let recordKey: String
    let conflict: SyncConflict
    let status: String
}

enum SyncConflictChoice { case local, server }

enum SyncRecoveryError: LocalizedError {
    case stalePage, invalidPayload, unsupportedRecord, staleConflict
    var errorDescription: String? {
        switch self {
        case .stalePage: "Sync progress changed. Fetch the next page again."
        case .invalidPayload: "Sync metadata failed validation. No changes from this page were saved."
        case .unsupportedRecord: "This sync record requires archive or collection support that is not enabled yet."
        case .staleConflict: "This conflict changed. Reload its current values before resolving it."
        }
    }
}
