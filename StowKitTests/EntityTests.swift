import XCTest
import CryptoKit
@testable import StowKit

@MainActor final class EntityTests: XCTestCase {
    private var root: URL!
    private var repository: ArchiveRepository!
    private var service: TextSearchService!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StowKitEntities-\(UUID())")
        repository = try ArchiveRepository(root: root)
        let container = repository.container
        service = await Task.detached { TextSearchService(modelContainer: container) }.value
        try await service.configure(root: root, archiveID: repository.archiveID)
    }
    override func tearDown() async throws { repository = nil; service = nil; try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func add(_ title: String, entities: String, trashed: Bool = false) throws -> HouseholdDocument {
        let bytes = Data("Fictional entity \(title) \(UUID())".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let id = UUID(), now = Date()
        try repository.insert(HouseholdDocument(id: id, archiveID: repository.archiveID, title: title, originalFilename: "f.pdf",
            documentDate: now, importedAt: now, modifiedAt: now, contentType: "com.adobe.pdf", contentHash: hash,
            fileSize: Int64(bytes.count), relativePath: "Originals/\(id.uuidString.prefix(2))/\(id).pdf"))
        var document = try XCTUnwrap(repository.document(id))
        document.entities = entities
        if trashed { document.trashedAt = now }
        try repository.update(document)
        return document
    }
    private let text = "Receipt for LG\nRefrigerator model LRMVS3006S, delivered to Etta Kessler. Home Depot"
    private func input() -> UnderstandingInput {
        let date = Date()
        return UnderstandingInput(document: HouseholdDocument(id: UUID(), archiveID: UUID(), title: "t", originalFilename: "t.pdf", documentDate: date,
            importedAt: date, modifiedAt: date, contentType: "com.adobe.pdf", contentHash: "", fileSize: 1, relativePath: ""),
            text: text, collections: [], truncated: false)
    }

    func testNamesAreKeptOnlyWhenTheTextContainsThem() {
        XCTAssertTrue(DocumentFacts.named("LG Refrigerator", in: text), "words may be split across lines")
        XCTAssertTrue(DocumentFacts.named("Etta", in: text), "short names are allowed")
        XCTAssertFalse(DocumentFacts.named("Samsung", in: text))
        XCTAssertFalse(DocumentFacts.named("Refrigerator LG", in: text), "the words must be in order")
        let result = UnderstandingPolicy.validated(DocumentUnderstanding(confidence: 0.7,
            entities: ["LG Refrigerator", "Samsung", "etta", "Etta", "Home Depot"]), input: input())
        XCTAssertEqual(result.entities, ["LG Refrigerator", "etta", "Home Depot"], "invented names dropped, duplicates merged")
    }
    func testSuggestedNamesJoinTheOwnersAndRespectProtection() {
        var document = input().document; document.entities = "Etta"
        let suggestion = DocumentUnderstanding(confidence: 0.7, entities: ["etta", "LG Refrigerator"])
        XCTAssertEqual(UnderstandingPolicy.merge(suggestion, into: document, protected: []).entities, "Etta, LG Refrigerator")
        XCTAssertEqual(UnderstandingPolicy.merge(suggestion, into: document, protected: ["entities"]).entities, "Etta")
        var unsure = suggestion; unsure.confidence = 0.3
        XCTAssertEqual(UnderstandingPolicy.merge(unsure, into: document, protected: []).entities, "Etta", "names need filing confidence")
    }
    func testDocumentsSharingAPersonOrThingAreRelated() async throws {
        let receipt = try add("Fridge receipt", entities: "LG Refrigerator, Etta")
        try add("Fridge warranty", entities: "lg refrigerator")
        try add("Fridge manual", entities: "LG Refrigerator; Etta")
        try add("School form", entities: "Etta")
        try add("Old fridge", entities: "LG Refrigerator", trashed: true)
        try add("Unrelated", entities: "")
        let related = try await service.related(to: receipt)
        XCTAssertEqual(related.first?.document.title, "Fridge manual", "most shared first")
        XCTAssertEqual(Set(related.map(\.document.title)), ["Fridge manual", "Fridge warranty", "School form"], "Trash and unrelated left out")
        let fridge = try await service.search("", destination: .recent, filter: LibraryFilter(entity: "LG REFRIGERATOR"), newestFirst: true)
        XCTAssertEqual(fridge.total, 3)
        let facets = try await service.facets()
        XCTAssertEqual(facets.entities.first.map { $0.count }, 3)
    }
    func testRenamingAnEntityAndItsKindPersist() throws {
        let one = try add("One", entities: "LG Refrigerator, Etta")
        try add("Two", entities: "lg refrigerator")
        XCTAssertEqual(try repository.renameEntity("LG REFRIGERATOR", to: "Kitchen fridge"), 2)
        XCTAssertEqual(try repository.document(one.id)?.entities, "Kitchen fridge, Etta")
        XCTAssertTrue(try XCTUnwrap(repository.analysis(one.id)).protectedFields.contains("entities"))
        try repository.saveEntityKinds(["kitchen fridge": .product, "etta": .person])
        repository = nil; repository = try ArchiveRepository(root: root)
        XCTAssertEqual(try repository.entityKinds()["etta"], .person)
    }
}
