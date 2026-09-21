import Foundation
import SwiftData

extension ArchiveRepository {
    func cloudBinding() throws -> (CloudArchiveBinding, Bool)? {
        guard let row = try context.fetch(FetchDescriptor<ArchiveSchemaV7.CloudBinding>()).first else { return nil }
        return (try JSONDecoder().decode(CloudArchiveBinding.self, from: row.payload), row.enabled)
    }
    func bindCloud(_ binding: CloudArchiveBinding) throws {
        guard binding.archiveID == archiveID else { throw SyncRecoveryError.invalidPayload }
        if let existing = try cloudBinding(), existing.0 != binding { throw CloudArchiveError.accountChanged }
        if let row = try context.fetch(FetchDescriptor<ArchiveSchemaV7.CloudBinding>()).first { row.enabled = true }
        else { context.insert(ArchiveSchemaV7.CloudBinding(payload: try JSONEncoder().encode(binding))) }
        try save()
    }
    func disableCloud() throws {
        for row in try context.fetch(FetchDescriptor<ArchiveSchemaV7.CloudBinding>()) { row.enabled = false }
        try save()
    }
    func originalCloudState(_ id: UUID) throws -> ArchiveSchemaV7.OriginalState? {
        try context.fetch(FetchDescriptor<ArchiveSchemaV7.OriginalState>(predicate: #Predicate { $0.documentID == id })).first
    }
    /// `OriginalState.pinned` has existed since V7 unused; wiring it needs no migration.
    func setOriginalPinned(_ id: UUID, _ pinned: Bool) throws {
        if let row = try originalCloudState(id) { row.pinned = pinned }
        else {
            let row = ArchiveSchemaV7.OriginalState(documentID: id, remote: false)
            row.pinned = pinned
            context.insert(row)
        }
        try save()
    }
    /// Collect every repository-owned fact eviction depends on. Deciding happens in
    /// `DocumentStorageManager.evictOriginal`, never here and never at a call site.
    func evictionFacts(_ id: UUID) throws -> EvictionFacts {
        var facts = EvictionFacts()
        let state = try originalCloudState(id)
        facts.pinned = state?.pinned ?? false
        facts.cloudVerified = state?.cloudVerified ?? false
        facts.remote = state?.remote ?? false
        // Anything short of a finished extraction may still need to read the original.
        let job = try processingJob(id)?.snapshot.state
        facts.processingOutstanding = !(job == .complete)
        if let binding = try cloudBinding(), binding.1 { facts.sharedArchive = binding.0.shared }
        else { facts.sharedArchive = true }
        return facts
    }
    func markOriginalVerified(_ id: UUID) throws {
        if let row = try originalCloudState(id) { row.cloudVerified = true }
        else { let row = ArchiveSchemaV7.OriginalState(documentID: id, remote: false); row.cloudVerified = true; context.insert(row) }
        try save()
    }
    func cloudRetryDate() throws -> Date? {
        let key = "cloud-retry-date"
        guard let row = try context.fetch(FetchDescriptor<Checkpoint>(predicate: #Predicate { $0.key == key })).first,
              let seconds = Double(row.value) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
    func setCloudRetryDate(_ date: Date?) throws {
        let key = "cloud-retry-date"
        let value = date.map { String($0.timeIntervalSince1970) } ?? ""
        if let row = try context.fetch(FetchDescriptor<Checkpoint>(predicate: #Predicate { $0.key == key })).first { row.value = value }
        else { context.insert(Checkpoint(key, value: value)) }
        try save()
    }
    func resetIncomingCloudToken() throws {
        let key = "incoming-token"
        for row in try context.fetch(FetchDescriptor<Checkpoint>(predicate: #Predicate { $0.key == key })) { row.value = "" }
        // Baselines, conflicts, originals, and pending writes survive a history reset.
        try save()
    }
}
