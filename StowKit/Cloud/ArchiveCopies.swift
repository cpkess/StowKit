import Foundation

/// Earlier builds could open this Mac's own iCloud archive a second time, into
/// `CloudArchives/<account>/<archive ID>`. That copy is a cache of the same archive, so it is
/// removed, but only once it provably holds nothing the real archive lacks: no unsent edits and
/// no document whose bytes the real archive doesn't have.
@MainActor enum ArchiveCopies {
    static func duplicates(of archiveID: UUID, under base: URL) -> [URL] {
        let accounts = (try? FileManager.default.contentsOfDirectory(at: base.appendingPathComponent("CloudArchives"),
            includingPropertiesForKeys: nil)) ?? []
        return accounts.map { $0.appendingPathComponent(archiveID.uuidString) }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Library.store").path) }
    }
    /// Returns the copies removed. A copy that still holds something unique is kept and reported.
    @discardableResult
    static func retire(duplicatesOf archive: ArchiveRepository, under base: URL) -> (removed: [URL], kept: [URL]) {
        var removed: [URL] = [], kept: [URL] = []
        for copy in duplicates(of: archive.archiveID, under: base) {
            if (try? isRedundant(copy, comparedWith: archive)) == true, (try? FileManager.default.removeItem(at: copy)) != nil {
                removed.append(copy)
            } else { kept.append(copy) }
        }
        return (removed, kept)
    }
    static func isRedundant(_ copy: URL, comparedWith archive: ArchiveRepository) throws -> Bool {
        let hashes = try Set(archive.documents().map(\.contentHash))
        let other = try ArchiveRepository(root: copy, joiningArchiveID: archive.archiveID)
        guard try other.pendingSyncOperations(limit: 1).isEmpty else { return false }
        return try other.documents().allSatisfy { hashes.contains($0.contentHash) }
    }
}
