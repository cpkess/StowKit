import XCTest
import SwiftData
import CryptoKit
@testable import StowKit

@MainActor final class DocumentFactsTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StowKitFacts-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private let bill = """
    Wood County Treasurer
    Statement date: September 3, 2026
    Amount due: $3,972.96
    Please pay by October 8, 2026. Coverage renews 2027-01-15.
    """
    private func document(imported: Date = Date(), date: Date? = nil) -> HouseholdDocument {
        HouseholdDocument(id: UUID(), archiveID: UUID(), title: "scan", originalFilename: "scan.pdf", documentDate: date ?? imported,
            importedAt: imported, modifiedAt: imported, contentType: "com.adobe.pdf", contentHash: String(repeating: "a", count: 64),
            fileSize: 1, relativePath: "Originals/aa/scan.pdf")
    }
    private func input(_ text: String) -> UnderstandingInput {
        UnderstandingInput(document: document(), text: text, collections: ["Taxes"], truncated: false)
    }

    // MARK: Checking against the text

    func testDatesAreKeptOnlyWhenTheTextContainsThem() {
        let days = DocumentFacts.detectedDays(in: bill)
        XCTAssertEqual(DocumentFacts.supportedDay("2026-09-03", among: days), "2026-09-03")
        XCTAssertEqual(DocumentFacts.supportedDay("2026-10-08", among: days), "2026-10-08")
        XCTAssertEqual(DocumentFacts.supportedDay("2027-01-15", among: days), "2027-01-15")
        XCTAssertNil(DocumentFacts.supportedDay("2026-09-04", among: days), "a day the document doesn't mention")
        XCTAssertNil(DocumentFacts.supportedDay("2026-02-30", among: days), "not a real day")
        XCTAssertNil(DocumentFacts.supportedDay("September 3", among: days), "not in the expected format")
    }
    func testAmountsAreKeptOnlyWhenTheirDigitsAppear() {
        XCTAssertEqual(DocumentFacts.supportedAmount("$3,972.96", in: bill), "$3,972.96")
        XCTAssertEqual(DocumentFacts.supportedAmount("3972.96 USD", in: bill), "3972.96 USD")
        XCTAssertNil(DocumentFacts.supportedAmount("$4,000.00", in: bill))
        XCTAssertNil(DocumentFacts.supportedAmount("paid in full", in: bill))
    }
    func testBuiltInRulesReadOnlyALabeledDate() {
        XCTAssertEqual(DocumentFacts.labeledDay(in: "Invoice date: March 15, 2026\nShipped April 2, 2026"), "2026-03-15")
        XCTAssertNil(DocumentFacts.labeledDay(in: "Shipped April 2, 2026"), "an unlabeled date isn't assumed to be the document's")
    }
    func testValidationDropsAnInventedDateOrAmount() {
        let result = UnderstandingPolicy.validated(DocumentUnderstanding(title: "Bill", confidence: 0.7,
            issuedOn: "2026-09-03", dueOn: "2026-11-01", amount: "$9.99"), input: input(bill))
        XCTAssertEqual(result.issuedOn, "2026-09-03")
        XCTAssertNil(result.dueOn, "November 1 isn't in the text")
        XCTAssertNil(result.amount)
    }

    // MARK: When facts fill a document

    func testAVerifiedDateReplacesOnlyTheImportDefault() throws {
        let day = try XCTUnwrap(DocumentFacts.date("2026-09-03"))
        let suggestion = DocumentUnderstanding(confidence: 0.3, issuedOn: "2026-09-03", dueOn: "2026-10-08", amount: "$3,972.96")
        let fresh = UnderstandingPolicy.merge(suggestion, into: document(), protected: [])
        XCTAssertEqual(fresh.documentDate, day, "filled even though filing is uncertain")
        XCTAssertEqual(fresh.amount, "$3,972.96")
        XCTAssertEqual(fresh.dueDate, DocumentFacts.date("2026-10-08"))
        XCTAssertTrue(fresh.needsReview)

        let named = document(date: Date(timeIntervalSinceNow: -86_400 * 400))
        XCTAssertEqual(UnderstandingPolicy.merge(suggestion, into: named, protected: []).documentDate, named.documentDate,
                       "a date that isn't the import day (from a filename, or set by hand before 1.5) is kept")
        XCTAssertEqual(UnderstandingPolicy.merge(suggestion, into: named, protected: [], explicit: true).documentDate, day,
                       "Use Suggestions is an explicit choice")
        XCTAssertEqual(UnderstandingPolicy.merge(suggestion, into: document(), protected: ["documentDate", "amount"]).amount, "",
                       "protected fields are never filled")
    }
    func testTypeFollowsFilingConfidence() {
        let unsure = UnderstandingPolicy.merge(DocumentUnderstanding(documentType: "Bill", confidence: 0.3), into: document(), protected: [])
        let sure = UnderstandingPolicy.merge(DocumentUnderstanding(documentType: "Bill", confidence: 0.7), into: document(), protected: [])
        XCTAssertEqual(unsure.documentType, "")
        XCTAssertEqual(sure.documentType, "Bill")
    }

    // MARK: Archive

    private func insert(_ repository: ArchiveRepository, title: String = "scan") throws -> HouseholdDocument {
        let bytes = Data("Fictional facts \(title) \(UUID())".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let id = UUID(), date = Date()
        let document = HouseholdDocument(id: id, archiveID: repository.archiveID, title: title, originalFilename: "scan.pdf",
            documentDate: date, importedAt: date, modifiedAt: date, contentType: "com.adobe.pdf", contentHash: hash,
            fileSize: Int64(bytes.count), relativePath: "Originals/\(id.uuidString.prefix(2))/\(id).pdf")
        try repository.insert(document)
        return try XCTUnwrap(repository.document(id))
    }
    func testEditingTheNewFieldsProtectsThem() throws {
        let repository = try ArchiveRepository(root: root)
        var edited = try insert(repository)
        edited.documentDate = Date(timeIntervalSinceNow: -86_400 * 30); edited.amount = "$12.00"; edited.dueDate = Date()
        try repository.update(edited)
        let protected = Set(try XCTUnwrap(repository.analysis(edited.id)).protectedFields)
        XCTAssertTrue(protected.isSuperset(of: ["documentDate", "amount", "dueDate"]))
        XCTAssertFalse(protected.contains("expiresAt"))
    }
    func testAVersion8ArchiveOpensAsVersion9WithItsDocuments() throws {
        let id = UUID(), date = Date()
        let old = HouseholdDocument(id: id, archiveID: UUID(), title: "Before 1.5", originalFilename: "old.pdf", documentDate: date,
            importedAt: date, modifiedAt: date, contentType: "com.adobe.pdf", contentHash: String(repeating: "b", count: 64),
            fileSize: 3, relativePath: "Originals/aa/old.pdf")
        do {
            let schema = Schema(versionedSchema: ArchiveSchemaV8.self)
            let configuration = ModelConfiguration("StowKit", schema: schema, url: root.appendingPathComponent("Library.store"), cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let archive = ArchiveSchemaV1.ArchiveRecord(); archive.id = old.archiveID
            context.insert(archive); context.insert(ArchiveSchemaV1.DocumentRecord(old))
            try context.save()
        }
        var repository: ArchiveRepository? = try ArchiveRepository(root: root)
        var migrated = try XCTUnwrap(repository?.document(id))
        XCTAssertEqual(migrated.title, "Before 1.5")
        XCTAssertEqual(migrated.documentType, "")
        XCTAssertNil(migrated.dueDate)
        migrated.amount = "$5.00"; migrated.expiresAt = date
        try repository?.update(migrated)
        repository = nil
        let reopened = try XCTUnwrap(ArchiveRepository(root: root).document(id))
        XCTAssertEqual(reopened.amount, "$5.00")
        XCTAssertNotNil(reopened.expiresAt)
    }

    // MARK: Sync compatibility

    private func journal(_ repository: ArchiveRepository, _ id: UUID) throws -> SyncMetadata {
        try JSONDecoder().decode(SyncMetadata.self, from: XCTUnwrap(repository.syncRecord("document:\(id)")).payload)
    }
    func testRecordsFromOlderAndNewerMacsBothApply() throws {
        let repository = try ArchiveRepository(root: root)
        let document = try insert(repository)
        let local = try journal(repository, document.id)
        XCTAssertEqual(local.fields["amount"]?.value, .text(""), "1.5 sends the new fields")

        var older = local
        for key in ArchiveRepository.addedInV9 { older.fields[key] = nil }
        older.fields["title"] = SyncField(value: .text("Renamed on a 1.4 Mac"), manual: true, operationID: UUID())
        try repository.applyIncomingPage(.init(previousToken: repository.incomingSyncToken(), nextToken: "t1", records: [older]))
        XCTAssertEqual(try repository.document(document.id)?.title, "Renamed on a 1.4 Mac", "a record without the new fields still applies")

        var newer = try journal(repository, document.id)
        newer.fields["someFutureField"] = SyncField(value: .text("from 1.9"), manual: false, operationID: UUID())
        newer.fields["amount"] = SyncField(value: .text("$7.50"), manual: true, operationID: UUID())
        try repository.applyIncomingPage(.init(previousToken: repository.incomingSyncToken(), nextToken: "t2", records: [newer]))
        XCTAssertEqual(try repository.document(document.id)?.amount, "$7.50")
        XCTAssertEqual(try journal(repository, document.id).fields["someFutureField"]?.value, .text("from 1.9"),
                       "an unknown field is carried along, not dropped or rejected")
    }
}
