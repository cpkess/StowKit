import XCTest
import CryptoKit
@testable import StowKit

/// The wording and date of a reminder, and the Upcoming view. Creating a real reminder needs the
/// owner's Reminders permission and writes to their Reminders, so no test does it.
@MainActor final class ReminderTests: XCTestCase {
    private func document(due: Date? = nil, expires: Date? = nil) -> HouseholdDocument {
        var document = HouseholdDocument(id: UUID(), archiveID: UUID(), title: "Property tax bill", originalFilename: "tax.pdf",
            documentDate: Date(), importedAt: Date(), modifiedAt: Date(), contentType: "com.adobe.pdf", contentHash: "", fileSize: 1, relativePath: "")
        document.correspondent = "Wood County Treasurer"; document.amount = "$3,972.96"
        document.dueDate = due; document.expiresAt = expires
        return document
    }
    func testADueDateBecomesA9AMReminderWithTheDetails() throws {
        let due = try XCTUnwrap(DocumentFacts.date("2026-10-08"))
        let draft = try XCTUnwrap(ReminderDraft.make(for: document(due: due), kind: .due))
        XCTAssertEqual(draft.title, "Due: Property tax bill")
        XCTAssertEqual(draft.notes, "From StowKit · Wood County Treasurer · $3,972.96")
        XCTAssertEqual(draft.due.year, 2026); XCTAssertEqual(draft.due.month, 10); XCTAssertEqual(draft.due.day, 8)
        XCTAssertEqual(draft.due.hour, 9)
        XCTAssertNil(ReminderDraft.make(for: document(due: due), kind: .expires), "no expiry date, no expiry reminder")
        XCTAssertEqual(ReminderDraft.make(for: document(expires: due), kind: .expires)?.title, "Renew or replace: Property tax bill")
    }
    func testUpcomingIncludesOverdueDueAndExpiringSoonOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StowKitUpcoming-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ArchiveRepository(root: root)
        let container = repository.container
        let service = await Task.detached { TextSearchService(modelContainer: container) }.value
        try await service.configure(root: root, archiveID: repository.archiveID)
        let today = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        func add(_ title: String, due: Int? = nil, expires: Int? = nil) throws {
            let bytes = Data("Fictional upcoming \(title) \(UUID())".utf8)
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let id = UUID()
            try repository.insert(HouseholdDocument(id: id, archiveID: repository.archiveID, title: title, originalFilename: "f.pdf", documentDate: today,
                importedAt: today, modifiedAt: today, contentType: "com.adobe.pdf", contentHash: hash, fileSize: Int64(bytes.count),
                relativePath: "Originals/\(id.uuidString.prefix(2))/\(id).pdf"))
            var document = try XCTUnwrap(repository.document(id))
            document.dueDate = due.map { today.addingTimeInterval(Double($0) * 86_400) }
            document.expiresAt = expires.map { today.addingTimeInterval(Double($0) * 86_400) }
            try repository.update(document)
        }
        try add("Overdue", due: -3); try add("Due soon", due: 20); try add("Expiring", expires: 60)
        try add("Expired long ago", expires: -30); try add("Far off", due: 200, expires: 400); try add("No dates")
        let page = try await service.search("", destination: .recent, filter: LibraryFilter(upcoming: .soon), newestFirst: true)
        XCTAssertEqual(Set(page.hits.map(\.document.title)), ["Overdue", "Due soon", "Expiring"])
    }
}
