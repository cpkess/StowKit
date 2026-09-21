import XCTest
import CryptoKit
@testable import StowKit

@MainActor final class OneArchiveTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StowKitOneArchive-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func zone(_ id: UUID = UUID(), shared: Bool = false) -> CloudArchiveBinding {
        CloudArchiveBinding(containerID: "iCloud.test", environment: "Development", accountID: "_owner", archiveID: id,
            zoneName: "StowKit-\(id)", ownerName: "__defaultOwner__", shared: shared)
    }
    private func facts(_ id: UUID = UUID(), documents: Int = 0, binding: (CloudArchiveBinding, Bool)? = nil,
                       paused: Bool = false, zones: [CloudArchiveBinding] = []) -> ArchiveFacts {
        ArchiveFacts(localArchiveID: id, documentCount: documents, binding: binding, pausedByOwner: paused, privateZones: zones)
    }
    @discardableResult
    private func seed(_ repository: ArchiveRepository, unique: String) throws -> HouseholdDocument {
        let bytes = Data("Fictional one-archive bytes \(unique)".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let id = UUID(), date = Date()
        let document = HouseholdDocument(id: id, archiveID: repository.archiveID, title: "scan.pdf", originalFilename: "scan.pdf",
            documentDate: date, importedAt: date, modifiedAt: date, contentType: "com.adobe.pdf", contentHash: hash,
            fileSize: Int64(bytes.count), relativePath: "Originals/\(id.uuidString.prefix(2))/\(id).pdf")
        try repository.insert(document)
        return document
    }
    private func acknowledgeAll(_ repository: ArchiveRepository) throws {
        try repository.acknowledgeSyncOperations(Set(repository.pendingSyncOperations(limit: 256).map(\.id)))
    }

    // MARK: Resolver

    func testEnabledBindingConnectsWithoutLookingFurther() {
        let id = UUID()
        XCTAssertEqual(ArchiveResolver.resolve(facts(id, documents: 5, binding: (zone(id), true), paused: true)), .connect)
    }
    func testBindingDisabledByTheOldSwitchBugReconnects() {
        let id = UUID()
        XCTAssertEqual(ArchiveResolver.resolve(facts(id, documents: 5, binding: (zone(id), false))), .connect)
    }
    func testOwnersPauseIsRespected() {
        let id = UUID()
        guard case .stayLocal = ArchiveResolver.resolve(facts(id, documents: 5, binding: (zone(id), false), paused: true)) else {
            return XCTFail("A paused archive must not reconnect")
        }
    }
    func testZoneForThisArchiveConnects() {
        let id = UUID()
        XCTAssertEqual(ArchiveResolver.resolve(facts(id, documents: 3, zones: [zone(), zone(id)])), .connect)
    }
    func testFirstArchiveUploadsSilentlyOnlyWhenEmpty() {
        XCTAssertEqual(ArchiveResolver.resolve(facts(documents: 0)), .upload(ask: false))
        XCTAssertEqual(ArchiveResolver.resolve(facts(documents: 12)), .upload(ask: true))
    }
    func testEmptyMacJoinsTheAccountsOneArchive() {
        let existing = zone()
        XCTAssertEqual(ArchiveResolver.resolve(facts(documents: 0, zones: [existing])), .join(existing))
    }
    func testNeverGuessesBetweenArchivesOrMergesSilently() {
        guard case .stayLocal = ArchiveResolver.resolve(facts(documents: 0, zones: [zone(), zone()])) else { return XCTFail("Two zones must not be guessed between") }
        guard case .stayLocal = ArchiveResolver.resolve(facts(documents: 4, zones: [zone()])) else { return XCTFail("Documents must not be merged silently") }
    }

    // MARK: Stale copies of this Mac's archive

    func testRememberedCopyOfThisMacsArchiveOpensTheRealArchive() {
        let own = UUID(), other = UUID(), base = URL(fileURLWithPath: "/tmp/StowKitBase")
        XCTAssertEqual(CloudSetup.root(for: "CloudArchives/abc/\(own)", thisMacArchiveID: own.uuidString, base: base), base)
        XCTAssertEqual(CloudSetup.root(for: "CloudArchives/abc/\(other)", thisMacArchiveID: own.uuidString, base: base),
                       base.appendingPathComponent("CloudArchives/abc/\(other)"))
        XCTAssertEqual(CloudSetup.root(for: "CloudArchives/../x", thisMacArchiveID: nil, base: base), base)
        XCTAssertEqual(CloudSetup.root(for: nil, thisMacArchiveID: own.uuidString, base: base), base)
    }
    func testRedundantCopyIsRemovedButOneWithUniqueContentIsKept() throws {
        let main = try ArchiveRepository(root: root)
        try seed(main, unique: "shared")
        let copyRoot = root.appendingPathComponent("CloudArchives/acct/\(main.archiveID)")
        do {
            let copy = try ArchiveRepository(root: copyRoot, joiningArchiveID: main.archiveID)
            try seed(copy, unique: "shared")
            try acknowledgeAll(copy)
        }
        XCTAssertEqual(ArchiveCopies.retire(duplicatesOf: main, under: root).removed.map(\.path), [copyRoot.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: copyRoot.path))

        do {
            let copy = try ArchiveRepository(root: copyRoot, joiningArchiveID: main.archiveID)
            try seed(copy, unique: "only in the copy")
            try acknowledgeAll(copy)
        }
        XCTAssertEqual(ArchiveCopies.retire(duplicatesOf: main, under: root).kept.map(\.path), [copyRoot.path], "A document the real archive lacks must survive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyRoot.path))
    }
    func testCopyWithUnsentEditsIsKept() throws {
        let main = try ArchiveRepository(root: root)
        try seed(main, unique: "shared")
        let copyRoot = root.appendingPathComponent("CloudArchives/acct/\(main.archiveID)")
        do {
            let copy = try ArchiveRepository(root: copyRoot, joiningArchiveID: main.archiveID)
            try seed(copy, unique: "shared")
        }
        XCTAssertEqual(ArchiveCopies.retire(duplicatesOf: main, under: root).kept.map(\.path), [copyRoot.path], "Unsent edits must survive")
    }
}
