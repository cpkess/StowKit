import Foundation

struct ImportResult {
    let document: HouseholdDocument
    let isDuplicate: Bool
}

@MainActor final class DocumentImporter {
    let repository: ArchiveRepository
    let storage: DocumentStorageManager
    init(repository: ArchiveRepository, storage: DocumentStorageManager) {
        self.repository = repository
        self.storage = storage
    }
    func importFile(_ source: URL) async throws -> ImportResult {
        let receipt = try await storage.stage(source)
        return try await commit(receipt)
    }
    func recover() async throws -> Int {
        let scan = try await storage.pendingReceipts()
        var count = 0
        var errors = scan.errors
        // A damaged recovery record must not prevent other valid imports from being committed.
        for receipt in scan.receipts {
            do { _ = try await commit(receipt); count += 1 }
            catch { errors.append("\(receipt.originalFilename): \(error.localizedDescription)") }
        }
        if !errors.isEmpty {
            throw NSError(domain: "StowKit.Recovery", code: 1, userInfo: [NSLocalizedDescriptionKey: errors.joined(separator: "\n")])
        }
        return count
    }
    private func commit(_ receipt: ImportReceipt) async throws -> ImportResult {
        if let existing = try repository.matching(hash: receipt.contentHash) {
            try await storage.discardDuplicate(receipt, existing: existing)
            return ImportResult(document: existing, isDuplicate: true)
        }
        try await storage.promote(receipt)
        // Another caller may have committed the same hash while promotion was awaited.
        if let existing = try repository.matching(hash: receipt.contentHash) {
            try await storage.discardDuplicate(receipt, existing: existing)
            return ImportResult(document: existing, isDuplicate: true)
        }
        let document = receipt.document(archiveID: repository.archiveID)
        try repository.insert(document)
        // If cleanup fails, the committed document is still safe; replay will deduplicate it.
        try? await storage.finish(receipt)
        return ImportResult(document: document, isDuplicate: false)
    }
}
