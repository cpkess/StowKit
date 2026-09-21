import XCTest
import CryptoKit
@testable import StowKit

@MainActor final class FilingRulesTests: XCTestCase {
    private var root: URL!
    private var repository: ArchiveRepository!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StowKitRules-\(UUID())")
        repository = try ArchiveRepository(root: root)
    }
    override func tearDown() async throws { repository = nil; try? FileManager.default.removeItem(at: root) }

    private let input = FilingRuleInput(title: "Patient Authorization FORM", sender: "", filename: "NovoCare_2026-09-17.pdf",
                                        text: "HIPAA authorization for the NovoCare program. Novo Nordisk Inc., Plainsboro NJ. Café fee 12.50")
    private func rule(_ terms: String, _ algorithm: FilingRule.Algorithm = .anyWord, in field: FilingRule.Field = .anything) -> FilingRule {
        FilingRule(name: "Test", field: field, algorithm: algorithm, terms: terms, collection: "Medical")
    }
    @discardableResult
    private func insert(_ title: String = "scan", text: String, unique: String = "") throws -> HouseholdDocument {
        let bytes = Data("Fictional rules bytes \(title) \(unique)".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let id = UUID(), date = Date()
        let document = HouseholdDocument(id: id, archiveID: repository.archiveID, title: title, originalFilename: "\(title).pdf",
            documentDate: date, importedAt: date, modifiedAt: date, contentType: "com.adobe.pdf", contentHash: hash,
            fileSize: Int64(bytes.count), relativePath: "Originals/\(id.uuidString.prefix(2))/\(id).pdf")
        try repository.insert(document)
        _ = try repository.setPageCount(id, count: 1)
        _ = try repository.savePage(id, index: 0, result: .init(text: text, method: .embedded))
        _ = try repository.setProcessingState(id, .complete)
        return try XCTUnwrap(repository.document(id))
    }

    // MARK: Matching

    func testWordsMatchWholeWordsIgnoringCaseAndAccents() {
        XCTAssertTrue(FilingRules.matches(rule("novocare"), input))
        XCTAssertTrue(FilingRules.matches(rule("CAFE"), input), "accents are ignored")
        XCTAssertFalse(FilingRules.matches(rule("novo care"), .init(title: "", sender: "", filename: "", text: "novocare")), "no partial words")
        XCTAssertTrue(FilingRules.matches(rule("zebra hipaa"), input), "any word")
        XCTAssertFalse(FilingRules.matches(rule("zebra hipaa", .allWords), input))
        XCTAssertTrue(FilingRules.matches(rule("hipaa nordisk", .allWords), input))
    }
    func testPhraseAndPatternAndFieldScope() {
        XCTAssertTrue(FilingRules.matches(rule("novo   NORDISK inc", .phrase), input), "whitespace and case are normalized")
        XCTAssertFalse(FilingRules.matches(rule("nordisk novo", .phrase), input))
        XCTAssertTrue(FilingRules.matches(rule("fee \\d+\\.\\d{2}", .pattern), input))
        XCTAssertFalse(FilingRules.matches(rule("fee (", .pattern), input), "an invalid expression never matches")
        XCTAssertTrue(FilingRules.matches(rule("novocare", in: .filename), input))
        XCTAssertFalse(FilingRules.matches(rule("hipaa", in: .title), input))
    }
    func testDisabledOrEmptyRulesNeverMatch() {
        var disabled = rule("novocare"); disabled.enabled = false
        XCTAssertFalse(FilingRules.matches(disabled, input))
        XCTAssertFalse(FilingRules.matches(rule("   "), input))
    }

    // MARK: Applying

    func testRuleCollectionReplacesTheSuggestedOneAndProtectedFieldsAreKept() throws {
        var before = try XCTUnwrap(repository.document(try insert(text: "x").id))
        before.collections = ["Home"]
        var suggested = before; suggested.collections.insert("Insurance"); suggested.correspondent = "Model guess"; suggested.needsReview = true
        var r = rule("novocare"); r.tags = "Health, insurance"; r.sender = "Novo Nordisk"
        let (edited, applied) = FilingRules.apply([r], to: suggested, before: before, input: input, protected: [], collections: ["Home", "Medical", "Insurance"])
        XCTAssertEqual(edited.collections, ["Home", "Medical"], "the rule's collection replaces the model's, and the owner's stays")
        XCTAssertEqual(edited.correspondent, "Novo Nordisk")
        XCTAssertEqual(edited.tags, "Health, insurance")
        XCTAssertFalse(edited.needsReview)
        XCTAssertEqual(applied, ["Test"])

        let (kept, _) = FilingRules.apply([r], to: suggested, before: before, input: input,
                                           protected: ["collections", "correspondent", "tags", "review"], collections: ["Medical"])
        XCTAssertEqual(kept, suggested, "fields the owner edited are never changed by a rule")
    }
    func testTagsAreAddedOnceAndMissingCollectionsIgnored() throws {
        var document = try XCTUnwrap(repository.document(try insert(text: "x").id)); document.tags = "health"
        var r = rule("novocare"); r.tags = "Health, bills"; r.collection = "Deleted Collection"; r.markReviewed = false
        let (edited, _) = FilingRules.apply([r], to: document, before: document, input: input, protected: [], collections: ["Medical"])
        XCTAssertEqual(edited.tags, "health, bills")
        XCTAssertEqual(edited.collections, document.collections)
    }

    // MARK: In the archive

    func testRulesRunWhenSuggestionsFinishEvenIfTheModelIsUnsure() throws {
        let document = try insert("NovoCare", text: "HIPAA authorization for the NovoCare program")
        try repository.saveFilingRules([rule("novocare")])
        let analysis = try XCTUnwrap(repository.analysis(document.id)); analysis.state = "analyzing"
        try repository.finishAnalysis(document.id, revision: analysis.revision, result: DocumentUnderstanding(title: "Form", confidence: 0.3))
        let filed = try XCTUnwrap(repository.document(document.id))
        XCTAssertEqual(filed.collections, ["Medical"])
        XCTAssertFalse(filed.needsReview, "a rule that marks reviewed files the document out of Inbox")
        XCTAssertEqual(try repository.analysis(document.id)?.snapshot.result?.rules, ["Test"])
        let pending = try repository.pendingSyncOperations().first { $0.metadata.recordKey == "document:\(document.id)" }
        XCTAssertEqual(pending?.metadata.fields["review"]?.value, .flag(false), "the rule's result syncs like any suggestion")
    }
    func testApplyToExistingDocumentsSkipsTrashAndCountsChanges() throws {
        try insert("First", text: "NovoCare statement", unique: "1")
        var trashed = try insert("Second", text: "NovoCare letter", unique: "2")
        trashed.trashedAt = Date(); try repository.update(trashed)
        try insert("Third", text: "Unrelated", unique: "3")
        try repository.saveFilingRules([rule("novocare")])
        XCTAssertEqual(try repository.applyFilingRulesToAll(), 1)
        XCTAssertEqual(try repository.applyFilingRulesToAll(), 0, "a second run changes nothing")
        XCTAssertTrue(try XCTUnwrap(repository.document(trashed.id)).collections.isEmpty)
    }
    func testRulesSurviveReopeningTheArchive() throws {
        try repository.saveFilingRules([rule("novocare"), rule("tax", in: .title)])
        repository = nil; repository = try ArchiveRepository(root: root)
        XCTAssertEqual(try repository.filingRules().map(\.terms), ["novocare", "tax"])
    }

    // MARK: Forward compatibility

    func testUnknownRecordTypeFromANewerMacDoesNotStallSync() throws {
        let rule = SyncMetadata(archiveID: repository.archiveID, recordKey: "rule:\(UUID())",
            fields: ["name": SyncField(value: .text("NovoCare"), manual: true, operationID: UUID())])
        let page = CloudChangePage(records: [CloudRecordSnapshot(metadata: rule, systemFields: Data("fields".utf8))], token: "t1", moreComing: false)
        XCTAssertNoThrow(try repository.applyCloudPage(page, after: ""))
        XCTAssertEqual(try repository.incomingSyncToken(), "t1")
        XCTAssertNotNil(try repository.cloudState(rule.recordKey), "kept for a later version to apply")
    }
}
