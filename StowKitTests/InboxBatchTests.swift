import XCTest
import CryptoKit
@testable import StowKit

@MainActor final class InboxBatchTests: XCTestCase {
    private var root: URL!
    private var repository: ArchiveRepository!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StowKitInboxBatch-\(UUID())")
        repository = try ArchiveRepository(root: root)
    }
    override func tearDown() async throws { repository = nil; try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func insert(_ title: String, review: Bool = true, text: String = "Fictional statement") throws -> HouseholdDocument {
        let bytes = Data("Fictional batch bytes \(title)".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let id = UUID(), date = Date()
        var document = HouseholdDocument(id: id, archiveID: repository.archiveID, title: title, originalFilename: "\(title).pdf",
            documentDate: date, importedAt: date, modifiedAt: date, contentType: "com.adobe.pdf", contentHash: hash,
            fileSize: Int64(bytes.count), relativePath: "Originals/\(id.uuidString.prefix(2))/\(id).pdf")
        document.needsReview = review
        try repository.insert(document)
        _ = try repository.setPageCount(id, count: 1)
        _ = try repository.savePage(id, index: 0, result: .init(text: text, method: .embedded))
        _ = try repository.setProcessingState(id, .complete)
        return try XCTUnwrap(repository.document(id))
    }
    private func suggest(_ document: HouseholdDocument, _ result: DocumentUnderstanding) throws {
        let analysis = try XCTUnwrap(repository.analysis(document.id)); analysis.state = "analyzing"
        try repository.finishAnalysis(document.id, revision: analysis.revision, result: result)
    }

    func testItemsAreEveryDocumentAwaitingReviewOutsideTrash() throws {
        let waiting = try insert("Waiting")
        try insert("Reviewed", review: false)
        var trashed = try insert("Trashed"); trashed.trashedAt = Date(); try repository.update(trashed)
        XCTAssertEqual(try repository.inboxBatchItems().map(\.id), [waiting.id])
    }
    func testSuggestForAllSkipsDocumentsAlreadyBeingRead() throws {
        let idle = try insert("Idle"), busy = try insert("Busy")
        try suggest(idle, DocumentUnderstanding(title: "Idle", confidence: 0.3))
        XCTAssertEqual(try repository.analysis(idle.id)?.state, "complete")
        let running = try XCTUnwrap(repository.analysis(busy.id)); running.state = "analyzing"; try repository.save()
        let before = running.revision
        XCTAssertEqual(try repository.requestAnalyses([idle.id, busy.id]), 1)
        XCTAssertEqual(try repository.analysis(idle.id)?.state, "queued")
        XCTAssertEqual(try repository.analysis(busy.id)?.revision, before, "an analysis in flight isn't restarted")
    }
    func testAcceptingWithAChosenCollectionOverridesTheSuggestion() throws {
        let document = try insert("Bill")
        try suggest(document, DocumentUnderstanding(title: "Electric bill", collection: "Home", correspondent: "", summary: "A bill.", confidence: 0.3))
        try repository.acceptSuggestion(document.id, collection: "Financial")
        let accepted = try XCTUnwrap(repository.document(document.id))
        XCTAssertEqual(accepted.collections, ["Financial"])
        XCTAssertEqual(accepted.title, "Electric bill")
        XCTAssertFalse(accepted.needsReview)
        XCTAssertTrue(try XCTUnwrap(repository.analysis(document.id)).protectedFields.contains("collections"), "the owner's choice is protected")
        XCTAssertTrue(try repository.inboxBatchItems().isEmpty)
    }
    func testAcceptingWithoutASuggestionOrWithAnUnknownCollection() throws {
        let plain = try insert("Plain")
        try repository.acceptSuggestion(plain.id, collection: "Medical")
        XCTAssertEqual(try repository.document(plain.id)?.collections, ["Medical"])
        let other = try insert("Other")
        try repository.acceptSuggestion(other.id, collection: "Deleted Collection")
        let accepted = try XCTUnwrap(repository.document(other.id))
        XCTAssertTrue(accepted.collections.isEmpty)
        XCTAssertFalse(accepted.needsReview)
    }
    func testUseSuggestionsStillAcceptsTheSuggestedCollection() throws {
        let document = try insert("Policy")
        try suggest(document, DocumentUnderstanding(title: "Policy", collection: "Insurance", confidence: 0.3))
        try repository.acceptAnalysis(document.id)
        XCTAssertEqual(try repository.document(document.id)?.collections, ["Insurance"])
    }
}
