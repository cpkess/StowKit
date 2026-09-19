import Foundation
import CloudKit
import AppKit
import CryptoKit

@MainActor enum CloudSetup {
    static var containerID: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "StowKitCloudContainer") as? String,
              value.hasPrefix("iCloud."), !value.contains("$(") else { return nil }
        return value
    }
    static var environment: String { Bundle.main.object(forInfoDictionaryKey: "StowKitCloudEnvironment") as? String ?? "Development" }
    static var activeRoot: URL {
        guard let relative = UserDefaults.standard.string(forKey: "StowKitArchiveRoot"),
              relative.hasPrefix("CloudArchives/"), !relative.contains("..") else { return DocumentStorageManager.defaultRoot }
        return DocumentStorageManager.defaultRoot.appendingPathComponent(relative)
    }
    static func privateBinding(archiveID: UUID) async throws -> CloudArchiveBinding {
        guard let containerID else { throw CloudArchiveError.setupRequired }
        let container = CKContainer(identifier: containerID)
        guard try await container.accountStatus() == .available else { throw CloudArchiveError.unavailable }
        let account = try await container.userRecordID().recordName
        let zone = CKRecordZone(zoneName: "StowKit-\(archiveID)")
        _ = try await container.privateCloudDatabase.save(zone)
        return CloudArchiveBinding(containerID: containerID, environment: environment, accountID: account,
            archiveID: archiveID, zoneName: zone.zoneID.zoneName, ownerName: zone.zoneID.ownerName, shared: false)
    }
    static func archives() async throws -> [CloudArchiveBinding] {
        guard let containerID else { throw CloudArchiveError.setupRequired }
        let container = CKContainer(identifier: containerID)
        let account = try await container.userRecordID().recordName
        var bindings: [CloudArchiveBinding] = []
        for shared in [false, true] {
            let database = shared ? container.sharedCloudDatabase : container.privateCloudDatabase
            for zone in try await database.allRecordZones() {
                guard zone.zoneID.zoneName.hasPrefix("StowKit-"),
                      let id = UUID(uuidString: String(zone.zoneID.zoneName.dropFirst(8))) else { continue }
                bindings.append(CloudArchiveBinding(containerID: containerID, environment: environment, accountID: account,
                    archiveID: id, zoneName: zone.zoneID.zoneName, ownerName: zone.zoneID.ownerName, shared: shared))
            }
        }
        return bindings
    }
    static func prepareArchive(_ binding: CloudArchiveBinding) throws -> URL {
        let account = SHA256.hash(data: Data("\(binding.containerID):\(binding.environment):\(binding.accountID):\(binding.ownerName)".utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let relative = "CloudArchives/\(account)/\(binding.archiveID)"
        let root = DocumentStorageManager.defaultRoot.appendingPathComponent(relative)
        let repository = try ArchiveRepository(root: root, joiningArchiveID: binding.archiveID)
        try repository.bindCloud(binding)
        UserDefaults.standard.set(relative, forKey: "StowKitArchiveRoot")
        return root
    }
    static func share(_ binding: CloudArchiveBinding) async throws {
        let container = CKContainer(identifier: binding.containerID)
        guard try await container.userRecordID().recordName == binding.accountID else { throw CloudArchiveError.accountChanged }
        let database = binding.shared ? container.sharedCloudDatabase : container.privateCloudDatabase
        let zone = CKRecordZone.ID(zoneName: binding.zoneName, ownerName: binding.ownerName)
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zone)
        let share: CKShare
        let found = try await database.records(for: [id])
        if let result = found[id] {
            do {
                guard let existing = try result.get() as? CKShare else { throw CloudArchiveError.missingResult }
                share = existing
            } catch let error as CKError where error.code == .unknownItem && !binding.shared {
                let created = CKShare(recordZoneID: zone); created.publicPermission = .none
                created[CKShare.SystemFieldKey.title] = "StowKit Household" as NSString
                let saved = try await database.modifyRecords(saving: [created], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
                guard let result = saved.saveResults[created.recordID], let value = try result.get() as? CKShare else { throw CloudArchiveError.missingResult }
                share = value
            }
        } else { throw CloudArchiveError.missingResult }
        let provider = NSItemProvider()
        provider.registerCKShare(share, container: container, allowedSharingOptions: CKAllowedSharingOptions(
            allowedParticipantPermissionOptions: [.readOnly, .readWrite], allowedParticipantAccessOptions: .specifiedRecipientsOnly))
        guard let service = NSSharingService(named: .cloudSharing), service.canPerform(withItems: [provider]) else { throw CloudArchiveError.unavailable }
        activeSharingService = service
        service.perform(withItems: [provider])
    }
    private static var activeSharingService: NSSharingService?
}

@MainActor final class StowKitAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Task {
            do {
                guard let configured = CloudSetup.containerID, metadata.containerIdentifier == configured,
                      metadata.share.recordID.zoneID.zoneName.hasPrefix("StowKit-"),
                      let archiveID = UUID(uuidString: String(metadata.share.recordID.zoneID.zoneName.dropFirst(8))) else { throw CloudArchiveError.setupRequired }
                let container = CKContainer(identifier: configured)
                let results = try await container.accept([metadata])
                guard let result = results[metadata] else { throw CloudArchiveError.missingResult }; _ = try result.get()
                let account = try await container.userRecordID().recordName, zone = metadata.share.recordID.zoneID
                let binding = CloudArchiveBinding(containerID: configured, environment: CloudSetup.environment, accountID: account,
                    archiveID: archiveID, zoneName: zone.zoneName, ownerName: zone.ownerName, shared: true)
                let root = try CloudSetup.prepareArchive(binding)
                NotificationCenter.default.post(name: .stowKitSwitchArchive, object: root)
            } catch {
                let alert = NSAlert(); alert.messageText = "Unable to Join Household"; alert.informativeText = error.localizedDescription; alert.runModal()
            }
        }
    }
}
extension Notification.Name { static let stowKitSwitchArchive = Notification.Name("StowKit.switchArchive") }
