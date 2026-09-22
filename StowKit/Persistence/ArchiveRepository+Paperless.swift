import Foundation

extension ArchiveRepository {
    /// Gives an imported file its paperless-ngx details. They were curated by the owner, so they go
    /// through `update`, which protects every field they change from later suggestions. A matching
    /// collection name (from the type or a tag) files the document; the paperless inbox tag keeps it
    /// in Inbox. Paperless's text is kept instead of reading the file again, unless StowKit has
    /// already started reading it.
    func applyPaperless(_ source: PaperlessDocument, to id: UUID) throws {
        guard var document = try document(id) else { throw ArchiveError.missingRecord }
        if !source.title.isEmpty { document.title = source.title }
        if let created = source.created { document.documentDate = created }
        document.correspondent = source.sender
        document.documentType = source.type
        document.tags = source.tags.filter { !$0.isEmpty }.joined(separator: ", ")
        document.summary = source.notes.joined(separator: " · ")
        document.amount = source.amount
        document.dueDate = source.dueDate
        document.expiresAt = source.expiresAt
        let names = Dictionary(try collections().map { ($0.name.lowercased(), $0.name) }, uniquingKeysWith: { first, _ in first })
        for candidate in [source.type] + source.tags { if let name = names[candidate.lowercased()] { document.collections.insert(name) } }
        document.needsReview = source.inbox
        document.modifiedAt = Date()
        try update(document)
        let text = source.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, try processingJob(id)?.state == "queued" {
            _ = try setPageCount(id, count: 1)
            _ = try savePage(id, index: 0, result: .init(text: text, method: .embedded))
            _ = try setProcessingState(id, .complete)
        }
    }
}
