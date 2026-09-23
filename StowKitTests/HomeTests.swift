import XCTest
import CryptoKit
@testable import StowKit

/// The home page's counts and the archive-wide search scope.
@MainActor final class HomeTests: XCTestCase {
    private var root: URL!
    private var repository: ArchiveRepository!
    private var service: TextSearchService!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StowKitHome-\(UUID())")
        repository = try ArchiveRepository(root: root)
        let container = repository.container
        service = await Task.detached { TextSearchService(modelContainer: container) }.value
        try await service.configure(root: root, archiveID: repository.archiveID)
    }
    override func tearDown() async throws { repository = nil; service = nil; try? FileManager.default.removeItem(at: root) }

    private let calendar = Calendar.current
    private func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date()))!.addingTimeInterval(12 * 3600) }
    @discardableResult
    private func add(_ title: String, body: String = "", due: Date? = nil, expires: Date? = nil,
                     collections: Set<String> = [], reviewed: Bool = true, trashed: Bool = false) throws -> HouseholdDocument {
        let bytes = Data("Fictional home \(title) \(UUID())".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let id = UUID(), now = Date()
        try repository.insert(HouseholdDocument(id: id, archiveID: repository.archiveID, title: title, originalFilename: "f.pdf",
            documentDate: now, importedAt: now, modifiedAt: now, contentType: "com.adobe.pdf", contentHash: hash,
            fileSize: 1_000, relativePath: "Originals/\(id.uuidString.prefix(2))/\(id).pdf"))
        var document = try XCTUnwrap(repository.document(id))
        document.dueDate = due; document.expiresAt = expires; document.collections = collections
        document.needsReview = !reviewed
        if trashed { document.trashedAt = now }
        try repository.update(document)
        if !body.isEmpty {
            _ = try repository.setPageCount(document.id, count: 1)
            _ = try repository.savePage(document.id, index: 0, result: .init(text: body, method: .embedded))
            _ = try repository.setProcessingState(document.id, .complete)
        }
        return document
    }

    func testOverviewCountsMatchWhatEachChipOpens() async throws {
        try add("Tax bill", due: day(10), collections: ["Taxes"])
        try add("Late invoice", due: day(-3), collections: ["Financial"])
        try add("Passport", expires: day(40), collections: ["Travel"])
        try add("Loose receipt", reviewed: false)
        try add("Thrown away", collections: ["Taxes"], trashed: true)

        let overview = try await service.overview()
        XCTAssertEqual(overview.statistics.documents, 5, "statistics count every record, Trash included")
        XCTAssertEqual(overview.statistics.inbox, 1, "only the unreviewed document is in the Inbox")
        XCTAssertEqual(overview.overdue, 1)
        XCTAssertEqual(overview.dueSoon, 1)
        XCTAssertEqual(overview.expiringSoon, 1)
        XCTAssertEqual(overview.unfiled, 1, "the loose receipt is in no collection; the trashed one doesn't count")
        XCTAssertEqual(overview.collections.map(\.name).sorted(), ["Financial", "Taxes", "Travel"],
                       "a collection with only a trashed document is left out")
        XCTAssertEqual(overview.collections.first { $0.name == "Taxes" }?.count, 1)

        // Each count must equal what clicking the chip shows.
        for (filter, expected) in [(LibraryFilter(upcoming: .overdue), overview.overdue),
                                   (LibraryFilter(upcoming: .dueSoon), overview.dueSoon),
                                   (LibraryFilter(upcoming: .expiringSoon), overview.expiringSoon),
                                   (LibraryFilter(noCollection: true), overview.unfiled)] {
            let page = try await service.search("", destination: .recent, filter: filter, newestFirst: true)
            XCTAssertEqual(page.total, expected, "the chip's count and its documents disagree for \(filter)")
        }
        let inbox = try await service.search("", destination: .inbox, filter: LibraryFilter(), newestFirst: true)
        XCTAssertEqual(inbox.total, overview.statistics.inbox)
    }

    func testSearchingEverywhereFindsWhatACollectionHides() async throws {
        try add("Tax bill", body: "Wood County Treasurer collected the levy", collections: ["Taxes"])
        try add("Vet invoice", body: "Wood County Treasurer paid the licence", collections: ["Pets"])

        let inTaxes = try await service.search("treasurer", destination: .collection("Taxes"), newestFirst: true)
        XCTAssertEqual(inTaxes.hits.map(\.document.title), ["Tax bill"], "a collection search stays inside it")
        let everywhere = try await service.search("treasurer", destination: nil, newestFirst: true)
        XCTAssertEqual(everywhere.hits.map(\.document.title).sorted(), ["Tax bill", "Vet invoice"])
        let unrelated = try await service.search("treasurer", destination: .collection("Travel"), newestFirst: true)
        XCTAssertEqual(unrelated.total, 0, "and the count offered as 'elsewhere' is the whole-archive one")
        XCTAssertEqual(everywhere.total, 2)
    }

    func testEverywhereKeepsFilterChipsAndNeverReachesIntoTrash() async throws {
        try add("Kept bill", body: "levy notice", collections: ["Taxes"])
        try add("Binned bill", body: "levy notice", collections: ["Taxes"], trashed: true)
        var overdueOnly = LibraryFilter(); overdueOnly.upcoming = .overdue

        let everywhere = try await service.search("levy", destination: nil, newestFirst: true)
        XCTAssertEqual(everywhere.hits.map(\.document.title), ["Kept bill"], "Trash is never searched from outside it")
        let filtered = try await service.search("levy", destination: nil, filter: overdueOnly, newestFirst: true)
        XCTAssertEqual(filtered.total, 0, "widening the destination does not drop the filter chips")
        let trash = try await service.search("levy", destination: .trash, newestFirst: true)
        XCTAssertEqual(trash.hits.map(\.document.title), ["Binned bill"])
    }
}
