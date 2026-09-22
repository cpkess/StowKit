import XCTest
import CryptoKit
@testable import StowKit

@MainActor final class FilterTests: XCTestCase {
    private var root: URL!
    private var repository: ArchiveRepository!
    private var service: TextSearchService!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StowKitFilters-\(UUID())")
        repository = try ArchiveRepository(root: root)
        let container = repository.container
        service = await Task.detached { TextSearchService(modelContainer: container) }.value
        try await service.configure(root: root, archiveID: repository.archiveID)
    }
    override func tearDown() async throws { repository = nil; service = nil; try? FileManager.default.removeItem(at: root) }

    private let calendar = Calendar.current
    private func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date()))!.addingTimeInterval(12 * 3600) }
    @discardableResult
    private func add(_ title: String, tags: String = "", sender: String = "", type: String = "", dated: Date? = nil,
                     due: Date? = nil, expires: Date? = nil, collections: Set<String> = [], trashed: Bool = false) throws -> HouseholdDocument {
        let bytes = Data("Fictional filter \(title) \(UUID())".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let id = UUID(), now = Date()
        try repository.insert(HouseholdDocument(id: id, archiveID: repository.archiveID, title: title, originalFilename: "f.pdf",
            documentDate: now, importedAt: now, modifiedAt: now, contentType: "com.adobe.pdf", contentHash: hash,
            fileSize: Int64(bytes.count), relativePath: "Originals/\(id.uuidString.prefix(2))/\(id).pdf"))
        var document = try XCTUnwrap(repository.document(id))
        document.tags = tags; document.correspondent = sender; document.documentType = type; document.documentDate = dated ?? now
        document.dueDate = due; document.expiresAt = expires; document.collections = collections
        if trashed { document.trashedAt = now }
        try repository.update(document)
        return document
    }
    private func titles(_ filter: LibraryFilter, query: String = "", destination: LibraryDestination? = .recent) async throws -> [String] {
        try await service.search(query, destination: destination, filter: filter, newestFirst: true).hits.map(\.document.title).sorted()
    }

    func testEachFilterNarrowsTheView() async throws {
        let lastYear = calendar.component(.year, from: Date()) - 1
        try add("Tax bill", tags: "Taxes, Home", sender: "Wood County Treasurer", type: "Bill",
                dated: calendar.date(from: DateComponents(year: lastYear, month: 6, day: 1)), due: day(10), collections: ["Taxes"])
        try add("Policy", tags: "insurance", sender: "State Farm", type: "Policy", expires: day(60))
        try add("Old bill", tags: "home", sender: "wood county treasurer", type: "bill", due: day(-5))
        try add("Thrown away", tags: "home", trashed: true)
        var tag = LibraryFilter(); tag.tag = "HOME"
        let homeTitles = try await titles(tag)
        XCTAssertEqual(homeTitles, ["Old bill", "Tax bill"], "tags match without case; Trash is excluded")
        let senderTitles = try await titles(LibraryFilter(sender: "Wood County Treasurer"))
        XCTAssertEqual(senderTitles, ["Old bill", "Tax bill"])
        let typeTitles = try await titles(LibraryFilter(type: "Policy"))
        XCTAssertEqual(typeTitles, ["Policy"])
        let yearTitles = try await titles(LibraryFilter(period: .lastYear))
        XCTAssertEqual(yearTitles, ["Tax bill"])
        let dueTitles = try await titles(LibraryFilter(upcoming: .dueSoon))
        XCTAssertEqual(dueTitles, ["Tax bill"])
        let overdueTitles = try await titles(LibraryFilter(upcoming: .overdue))
        XCTAssertEqual(overdueTitles, ["Old bill"])
        let expiringTitles = try await titles(LibraryFilter(upcoming: .expiringSoon))
        XCTAssertEqual(expiringTitles, ["Policy"])
        let uncollected = try await titles(LibraryFilter(noCollection: true))
        XCTAssertEqual(uncollected, ["Old bill", "Policy"])
        let combined = try await titles(LibraryFilter(tag: "home", upcoming: .dueSoon), query: "tax")
        XCTAssertEqual(combined, ["Tax bill"], "filters combine with each other and with search")
        let inCollection = try await titles(LibraryFilter(tag: "home"), destination: .collection("Taxes"))
        XCTAssertEqual(inCollection, ["Tax bill"])
    }
    func testFacetsCountWithoutCaseAndSkipTrash() async throws {
        try add("A", tags: "Home, taxes", sender: "Wood County", type: "Bill")
        try add("B", tags: "home", sender: "wood county", type: "bill")
        try add("C", tags: "Home", trashed: true)
        let facets = try await service.facets()
        XCTAssertEqual(facets.tags.first?.count, 2, "Home and home are one tag; the trashed one doesn't count")
        XCTAssertEqual(facets.tags.map(\.name).count, 2)
        XCTAssertEqual(facets.senders.first?.count, 2)
        XCTAssertEqual(facets.types.first?.count, 2)
        XCTAssertEqual(facets.years, [calendar.component(.year, from: Date())])
    }
    func testRenamingATagMergesAndProtects() throws {
        let one = try add("One", tags: "Home, bills")
        let two = try add("Two", tags: "home, House")
        let trashed = try add("Three", tags: "home", trashed: true)
        XCTAssertEqual(try repository.renameTag("HOME", to: "House"), 2)
        XCTAssertEqual(try repository.document(one.id)?.tags, "House, bills")
        XCTAssertEqual(try repository.document(two.id)?.tags, "House", "renaming onto an existing tag merges them")
        XCTAssertEqual(try repository.document(trashed.id)?.tags, "home", "Trash is left alone")
        XCTAssertTrue(try XCTUnwrap(repository.analysis(one.id)).protectedFields.contains("tags"))
        XCTAssertEqual(try repository.renameTag("bills", to: ""), 1)
        XCTAssertEqual(try repository.document(one.id)?.tags, "House")
    }
    func testSavedViewsSurviveReopening() throws {
        let view = SavedView(name: "Taxes last year", destination: .collection("Taxes"), query: "receipt", filter: LibraryFilter(tag: "home", period: .lastYear))
        try repository.saveSavedViews([view])
        repository = nil; repository = try ArchiveRepository(root: root)
        XCTAssertEqual(try repository.savedViews(), [view])
    }
}
