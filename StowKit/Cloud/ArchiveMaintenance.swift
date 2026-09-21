#if STOWKIT_ARCHIVE_MAINTENANCE
import Foundation
import CloudKit
import AppKit

/// One-off maintenance runner, compiled only with `STOWKIT_ARCHIVE_MAINTENANCE` and never
/// distributed (`scripts/build-distribution.sh` clears compilation conditions). It removes the
/// fictional archives left in iCloud by `CloudLiveVerification` runs.
///
/// Deleting an iCloud zone is irreversible, so it is conservative by construction: it identifies
/// the owner's own archive from the local database and never touches it, deletes another zone only
/// if every document in it is fictional test data, and only reports unless launched with --delete.
@MainActor enum ArchiveMaintenance {
    static func run() async {
        let delete = CommandLine.arguments.contains("--delete")
        func say(_ line: String) { print("STOWKIT_MAINT: \(line)"); fflush(stdout) }
        do {
            guard let containerID = CloudSetup.containerID, CloudSetup.environment == "Production" else {
                throw CloudArchiveError.setupRequired
            }
            let home = DocumentStorageManager.defaultRoot
            guard FileManager.default.fileExists(atPath: home.appendingPathComponent("Library.store").path) else {
                say("ABORT this Mac's archive was not found, so it cannot be protected"); throw CloudArchiveError.setupRequired
            }
            let own = try ArchiveRepository(root: home)
            let ownID = own.archiveID
            say("mode \(delete ? "DELETE" : "DRY RUN"); protecting this Mac's archive \(ownID)")
            let database = CKContainer(identifier: containerID).privateCloudDatabase
            var deleted: [UUID] = []
            for zone in try await database.allRecordZones() where zone.zoneID.zoneName.hasPrefix("StowKit-") {
                guard let id = UUID(uuidString: String(zone.zoneID.zoneName.dropFirst(8))) else { continue }
                if id == ownID { say("KEEP \(zone.zoneID.zoneName) — this Mac's own archive"); continue }
                let documents = try await documentTexts(in: zone.zoneID, database: database)
                let fictional = documents.allSatisfy { $0.localizedCaseInsensitiveContains("fictional") }
                say("zone \(zone.zoneID.zoneName): \(documents.count) document(s); all fictional: \(fictional)")
                for text in documents { say("    \(text.prefix(120))") }
                guard fictional else { say("KEEP \(zone.zoneID.zoneName) — contains non-test documents"); continue }
                if delete {
                    try await database.deleteRecordZone(withID: zone.zoneID)
                    deleted.append(id); say("DELETED \(zone.zoneID.zoneName)")
                } else { say("WOULD DELETE \(zone.zoneID.zoneName)") }
            }
            if delete { try removeLocalCopies(of: deleted, under: home, say: say) }
            say("DONE")
        } catch { say("FAIL \(error.localizedDescription)") }
        NSApplication.shared.terminate(nil)
    }

    /// Title, filename, and summary of each document record, which is enough to recognize the
    /// verification runner's "Fictional…" fixtures.
    private static func documentTexts(in zone: CKRecordZone.ID, database: CKDatabase) async throws -> [String] {
        var texts: [String] = [], token: CKServerChangeToken?
        repeat {
            let page = try await database.recordZoneChanges(inZoneWith: zone, since: token, desiredKeys: ["metadata"], resultsLimit: 200)
            for (_, result) in page.modificationResultsByID {
                let record = try result.get().record
                guard record.recordType == "StowMetadata", record.recordID.recordName.hasPrefix("document:"),
                      let data = record.encryptedValues["metadata"] as? Data else { continue }
                let metadata = try JSONDecoder().decode(SyncMetadata.self, from: data)
                let parts = ["title", "originalFilename", "summary"].compactMap { key -> String? in
                    if case .text(let value) = metadata.fields[key]?.value { return value } else { return nil }
                }
                texts.append(parts.joined(separator: " | "))
            }
            token = page.changeToken
            if !page.moreComing { break }
        } while true
        return texts
    }

    /// The runner's own fixture folder, plus local caches of the zones just deleted. Nothing else.
    private static func removeLocalCopies(of ids: [UUID], under home: URL, say: (String) -> Void) throws {
        let files = FileManager.default
        let validation = home.appendingPathComponent("CloudValidation")
        if files.fileExists(atPath: validation.path) { try files.removeItem(at: validation); say("removed CloudValidation/") }
        let caches = home.appendingPathComponent("CloudArchives")
        for account in (try? files.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)) ?? [] {
            for id in ids {
                let folder = account.appendingPathComponent(id.uuidString)
                if files.fileExists(atPath: folder.path) { try files.removeItem(at: folder); say("removed local cache \(id)") }
            }
        }
        if let saved = UserDefaults.standard.string(forKey: "StowKitArchiveRoot"), ids.contains(where: { saved.contains($0.uuidString) }) {
            UserDefaults.standard.removeObject(forKey: "StowKitArchiveRoot"); say("reset the saved archive choice to this Mac")
        }
    }
}
#endif
