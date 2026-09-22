import Foundation
import CryptoKit

/// One exported document, as `manifest.json` records it.
struct ExportRecord: Codable, Equatable, Sendable {
    let id: UUID
    let title: String
    let file: String
    let textFile: String?
    let originalFilename: String
    let contentType: String
    let sha256: String
    let fileSize: Int64
    let documentDate: String
    let importedAt: String
    let sender: String
    let collections: [String]
    let tags: [String]
    let summary: String
    let peopleAndThings: String
    let favorite: Bool
    let needsReview: Bool
    var documentType = ""
    var amount = ""
    var dueDate: String?
    var expiresAt: String?
}

struct ExportResult: Sendable {
    let folder: URL
    let exported: Int
    let failures: [String]
}

/// Writes the archive as plain files anyone can read without StowKit: originals named by date
/// and title in a folder per collection, their text, and a manifest in JSON and CSV. Every copied
/// original is re-hashed and must match its recorded SHA-256, so a finished export is a verified
/// one. The folder carries `.partial` until everything is written.
actor ArchiveExporter {
    private let storage: DocumentStorageManager
    private let reader: TextSearchService
    private let files = FileManager.default
    init(storage: DocumentStorageManager, reader: TextSearchService) { self.storage = storage; self.reader = reader }

    func export(_ documents: [HouseholdDocument], into parent: URL, at date: Date = Date(),
                progress: @escaping @Sendable (Int, Int) async -> Void) async throws -> ExportResult {
        let name = "StowKit Export \(Self.stamp(date))"
        let partial = parent.appendingPathComponent(name + ".partial", isDirectory: true)
        let final = Self.unique(parent.appendingPathComponent(name, isDirectory: true), files: files)
        try files.createDirectory(at: partial, withIntermediateDirectories: true)
        var records: [ExportRecord] = [], failures: [String] = [], used = Set<String>()
        for (index, document) in documents.enumerated() {
            try Task.checkCancellation()
            await progress(index, documents.count)
            do {
                let relative = Self.relativePath(for: document, taken: &used)
                let destination = partial.appendingPathComponent("Documents").appendingPathComponent(relative)
                try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let source = try await storage.localOriginal(for: document)
                try Self.copyVerifying(source, to: destination, sha256: document.contentHash)
                let text = try await reader.pages(for: document.id).map(\.text).joined(separator: "\n\n")
                var textFile: String?
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let path = (relative as NSString).deletingPathExtension + ".txt"
                    let url = partial.appendingPathComponent("Text").appendingPathComponent(path)
                    try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(text.utf8).write(to: url, options: .atomic)
                    textFile = "Text/" + path
                }
                records.append(Self.record(document, file: "Documents/" + relative, textFile: textFile))
            } catch is CancellationError { throw CancellationError() }
            catch { failures.append("\(document.title): \(error.localizedDescription)") }
        }
        await progress(documents.count, documents.count)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: partial.appendingPathComponent("manifest.json"), options: .atomic)
        try Data(Self.csv(records).utf8).write(to: partial.appendingPathComponent("manifest.csv"), options: .atomic)
        try Data(Self.readme(date: date, count: records.count, failures: failures).utf8)
            .write(to: partial.appendingPathComponent("README.txt"), options: .atomic)
        try files.moveItem(at: partial, to: final)
        return ExportResult(folder: final, exported: records.count, failures: failures)
    }

    // MARK: Pure pieces, tested directly

    /// `Collection/2026-09-17 Title.pdf`, with the first collection alphabetically as the folder
    /// (the manifest lists them all) and `Unfiled` for none. Clashes get " (2)", " (3)"…
    static func relativePath(for document: HouseholdDocument, taken: inout Set<String>) -> String {
        let folder = document.collections.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.first.map(safe) ?? "Unfiled"
        let ext = URL(fileURLWithPath: document.originalFilename).pathExtension.lowercased()
        let title = safe(document.title.isEmpty ? URL(fileURLWithPath: document.originalFilename).deletingPathExtension().lastPathComponent : document.title)
        let base = "\(folder)/\(day(document.documentDate)) \(title)"
        var candidate = "\(base).\(ext)", copy = 2
        while taken.contains(candidate.lowercased()) { candidate = "\(base) (\(copy)).\(ext)"; copy += 1 }
        taken.insert(candidate.lowercased())
        return candidate
    }
    static func safe(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t")).joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return String((cleaned.isEmpty ? "Untitled" : cleaned).prefix(120))
    }
    static func copyVerifying(_ source: URL, to destination: URL, sha256 expected: String) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        do {
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var hasher = SHA256()
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty { try output.write(contentsOf: chunk); hasher.update(data: chunk) }
            try output.synchronize()
            guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { throw ExportError.mismatch }
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
    static func csv(_ records: [ExportRecord]) -> String {
        func field(_ value: String) -> String {
            value.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
        }
        let header = "Title,Date,Sender,Type,Amount,Due,Expires,Collections,Tags,Summary,File,SHA-256,Needs Review"
        let rows = records.map { record in
            [record.title, record.documentDate, record.sender, record.documentType, record.amount, record.dueDate ?? "", record.expiresAt ?? "",
             record.collections.joined(separator: "; "), record.tags.joined(separator: "; "),
             record.summary, record.file, record.sha256, record.needsReview ? "yes" : "no"].map(field).joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }
    private static func record(_ document: HouseholdDocument, file: String, textFile: String?) -> ExportRecord {
        ExportRecord(id: document.id, title: document.title, file: file, textFile: textFile, originalFilename: document.originalFilename,
            contentType: document.contentType, sha256: document.contentHash, fileSize: document.fileSize,
            documentDate: day(document.documentDate), importedAt: ISO8601DateFormatter().string(from: document.importedAt),
            sender: document.correspondent, collections: document.collections.sorted(),
            tags: document.tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            summary: document.summary, peopleAndThings: document.entities, favorite: document.favorite, needsReview: document.needsReview,
            documentType: document.documentType, amount: document.amount, dueDate: document.dueDate.map(day), expiresAt: document.expiresAt.map(day))
    }
    private static func readme(date: Date, count: Int, failures: [String]) -> String {
        var text = """
        StowKit export, \(date.formatted(date: .long, time: .shortened))

        \(count) documents. Everything here is plain files; StowKit is not needed to read it.

        Documents/   The original files, byte for byte, in a folder per collection ("Unfiled" for
                     none). A document in several collections is stored once, in the first one
                     alphabetically; manifest.json lists all of its collections.
        Text/        The text StowKit read from each document, where it found any.
        manifest.json and manifest.csv
                     Title, date, sender, collections, tags, summary, and the SHA-256 of each
                     original. Every original was re-hashed after copying and matched.

        Documents in StowKit's Trash are not included.
        """
        if !failures.isEmpty { text += "\n\nNot exported:\n" + failures.map { "  • " + $0 }.joined(separator: "\n") }
        return text + "\n"
    }
    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter.string(from: date)
    }
    private static func unique(_ url: URL, files: FileManager) -> URL {
        var candidate = url, copy = 2
        while files.fileExists(atPath: candidate.path) { candidate = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent) \(copy)"); copy += 1 }
        return candidate
    }
}

enum ExportError: LocalizedError {
    case mismatch
    var errorDescription: String? { "The copy didn't match the original's fingerprint, so it was left out." }
}
