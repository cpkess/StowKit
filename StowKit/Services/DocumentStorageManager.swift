import Foundation
import CryptoKit
import UniformTypeIdentifiers
import CoreGraphics
import ImageIO

struct ImportReceipt: Codable, Sendable {
    let id: UUID
    let originalFilename: String
    let contentType: String
    let contentHash: String
    let fileSize: Int64
    let importedAt: Date
    let relativePath: String

    func document(archiveID: UUID) -> HouseholdDocument {
        HouseholdDocument(id: id, archiveID: archiveID,
            title: URL(fileURLWithPath: originalFilename).deletingPathExtension().lastPathComponent,
            originalFilename: originalFilename, documentDate: importedAt, importedAt: importedAt,
            modifiedAt: importedAt, contentType: contentType, contentHash: contentHash,
            fileSize: fileSize, relativePath: relativePath)
    }
}

/// Serial file operations execute on the actor's executor, never on the UI actor.
/// A receipt remains durable until both the original and its metadata are committed.
actor DocumentStorageManager {
    nonisolated let root: URL
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StowKit", isDirectory: true)
    }
    static let supportedTypes: [UTType] = [.pdf, .jpeg, .png, .heic]
    private let files = FileManager.default
    private var cloud: (any ArchiveCloudTransport)?
    private var downloads: [UUID: Task<URL, Error>] = [:]
    func setCloudTransport(_ transport: (any ArchiveCloudTransport)?) {
        cloud = transport
        if transport == nil { for task in downloads.values { task.cancel() } }
    }
    init(root: URL) { self.root = root }

    nonisolated func originalURL(for relativePath: String) throws -> URL {
        let parts = relativePath.split(separator: "/")
        guard parts.count == 3, parts[0] == "Originals", parts[1].count == 2,
              UUID(uuidString: URL(fileURLWithPath: String(parts[2])).deletingPathExtension().lastPathComponent) != nil,
              !relativePath.contains("..") else { throw ArchiveError.unsafePath }
        return root.appendingPathComponent(relativePath)
    }
    func cachedOriginal(for document: HouseholdDocument) async throws -> URL? {
        let url = try originalURL(for: document.relativePath)
        guard files.fileExists(atPath: url.path) else { return nil }
        return try await localOriginal(for: document)
    }
    func canDownloadOriginals() -> Bool { cloud != nil }
    /// Consumer boundary for originals. Future downloads/leases belong here.
    /// Import already verifies hashes; opening checks presence/type/size without rehashing each preview.
    func localOriginal(for document: HouseholdDocument) async throws -> URL {
        let url = try originalURL(for: document.relativePath)
        if !files.fileExists(atPath: url.path) {
            guard let cloud else { throw OriginalAccessError.missing }
            if let task = downloads[document.id] { return try await task.value }
            let task = Task { try await self.download(document, transport: cloud) }
            downloads[document.id] = task
            defer { downloads[document.id] = nil }
            return try await task.value
        }
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attributes.isRegularFile == true, Int64(attributes.fileSize ?? -1) == document.fileSize else {
            throw ArchiveError.recoveryMismatch
        }
        return url
    }

    private func download(_ document: HouseholdDocument, transport: any ArchiveCloudTransport) async throws -> URL {
        let directory = root.appendingPathComponent("Transfers/\(document.id)")
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = directory.appendingPathComponent("download")
        try await transport.downloadOriginal(document, to: staged)
        try await transport.verifyAccount()
        try Task.checkCancellation()
        guard try hash(staged) == document.contentHash else { throw CloudArchiveError.corruptAsset }
        let original = try originalURL(for: document.relativePath)
        try files.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        if files.fileExists(atPath: original.path) {
            guard try hash(original) == document.contentHash else { throw CloudArchiveError.corruptAsset }
        } else {
            try files.moveItem(at: staged, to: original)
            try files.setAttributes([.posixPermissions: 0o400], ofItemAtPath: original.path)
        }
        try? files.removeItem(at: directory)
        return original
    }
    func verifyCloudOriginal(_ document: HouseholdDocument, transport: any ArchiveCloudTransport) async throws {
        let directory = root.appendingPathComponent("Transfers/Verify-\(document.id)")
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("download")
        try await transport.downloadOriginal(document, to: file)
        try Task.checkCancellation()
        guard try hash(file) == document.contentHash else { throw CloudArchiveError.corruptAsset }
        try? files.removeItem(at: directory)
    }
    /// Walk the archive and report allocated bytes per category. Deliberately measures the disk
    /// rather than summing recorded document sizes, which count documents that are trashed or
    /// have never been downloaded. Callers treat this as a report, not as a cached value.
    func usage() throws -> ArchiveUsage {
        var usage = ArchiveUsage()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let walker = files.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return usage }
        for case let url as URL in walker {
            try Task.checkCancellation()
            guard let values = try? url.resourceValues(forKeys: keys) else { usage.unreadable += 1; continue }
            guard values.isRegularFile == true else { continue }
            let bytes = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            switch root.path.count < url.path.count
                ? url.path.dropFirst(root.path.count).split(separator: "/").first.map(String.init) : nil {
            case "Originals": usage.originals += bytes; usage.originalFiles += 1
            case "Thumbnails": usage.thumbnails += bytes
            case "Search": usage.searchIndex += bytes
            case "Staging": usage.staging += bytes
            case "Transfers": usage.transfers += bytes
            case let name? where name.hasPrefix("Library.store"): usage.database += bytes
            default: usage.other += bytes
            }
        }
        return usage
    }
    nonisolated func thumbnailURL(for id: UUID) -> URL {
        root.appendingPathComponent("Thumbnails/\(id.uuidString).png")
    }
    private func stagingURL(_ id: UUID) -> URL { root.appendingPathComponent("Staging/\(id.uuidString)", isDirectory: true) }
    private func stagedOriginal(_ receipt: ImportReceipt) -> URL {
        stagingURL(receipt.id).appendingPathComponent("original.\(URL(fileURLWithPath: receipt.relativePath).pathExtension)")
    }

    func prepare() throws {
        for folder in ["Originals", "Staging", "Thumbnails"] {
            try files.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
    }

    func stage(_ source: URL) throws -> ImportReceipt {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard source.isFileURL, let type = UTType(filenameExtension: source.pathExtension),
              Self.supportedTypes.contains(where: { type.conforms(to: $0) }) else { throw ArchiveError.unsupportedType }
        let id = UUID()
        let directory = stagingURL(id)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = type.conforms(to: .pdf) ? "pdf" : (type.preferredFilenameExtension ?? source.pathExtension.lowercased())
        let destination = directory.appendingPathComponent("original.\(ext)")
        do {
            var result: Result<ImportReceipt, Error>?
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinated in
                result = Result {
                    let before = try coordinated.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                    guard before.isRegularFile == true, (before.fileSize ?? 0) > 0 else { throw ArchiveError.invalidDocument }
                    let digest = try copyAndHash(from: coordinated, to: destination)
                    var refreshed = coordinated
                    refreshed.removeAllCachedResourceValues()
                    let after = try refreshed.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    guard Int64(before.fileSize ?? 0) == digest.size,
                          before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else {
                        throw ArchiveError.changedSource
                    }
                    let actualType = try validate(destination, expectedType: type)
                    return ImportReceipt(id: id, originalFilename: source.lastPathComponent,
                        contentType: actualType, contentHash: digest.hash, fileSize: digest.size, importedAt: Date(),
                        relativePath: "Originals/\(id.uuidString.prefix(2))/\(id.uuidString).\(ext)")
                }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw ArchiveError.invalidDocument }
            let receipt = try result.get()
            try JSONEncoder().encode(receipt).write(to: directory.appendingPathComponent("receipt.json"), options: .atomic)
            return receipt
        } catch {
            // No durable receipt was published; only this unsuccessful staging copy is removed.
            try? files.removeItem(at: directory)
            throw error
        }
    }

    func pendingReceipts() throws -> (receipts: [ImportReceipt], errors: [String]) {
        try prepare()
        let directories = try files.contentsOfDirectory(at: root.appendingPathComponent("Staging"), includingPropertiesForKeys: nil)
        var receipts: [ImportReceipt] = []
        var errors: [String] = []
        for directory in directories {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            let manifest = directory.appendingPathComponent("receipt.json")
            guard files.fileExists(atPath: manifest.path) else {
                // Interrupted streaming copy. The source was never modified and no record was committed.
                do { try files.removeItem(at: directory) }
                catch { errors.append("Incomplete import \(id): \(error.localizedDescription)") }
                continue
            }
            do {
                let receipt = try JSONDecoder().decode(ImportReceipt.self, from: Data(contentsOf: manifest))
                guard receipt.id == id,
                      URL(fileURLWithPath: receipt.relativePath).deletingPathExtension().lastPathComponent == id.uuidString else {
                    throw ArchiveError.recoveryMismatch
                }
                _ = try originalURL(for: receipt.relativePath)
                receipts.append(receipt)
            } catch { errors.append("Recovery record \(id): \(error.localizedDescription)") }
        }
        return (receipts.sorted { $0.importedAt < $1.importedAt }, errors)
    }

    func promote(_ receipt: ImportReceipt) throws {
        let destination = try originalURL(for: receipt.relativePath)
        if files.fileExists(atPath: destination.path) {
            guard try hash(destination) == receipt.contentHash else { throw ArchiveError.recoveryMismatch }
            return // Recovery after rename, before metadata save.
        }
        let staged = stagedOriginal(receipt)
        guard try hash(staged) == receipt.contentHash else { throw ArchiveError.recoveryMismatch }
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.moveItem(at: staged, to: destination) // Atomic rename on the same volume.
        try files.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
    }
    func finish(_ receipt: ImportReceipt) throws {
        let directory = stagingURL(receipt.id)
        if files.fileExists(atPath: directory.path) { try files.removeItem(at: directory) }
    }
    func discardDuplicate(_ receipt: ImportReceipt, existing: HouseholdDocument) throws {
        let original = try originalURL(for: existing.relativePath)
        // Never discard the imported copy if the existing archive copy cannot be verified.
        guard try hash(original) == existing.contentHash else { throw ArchiveError.recoveryMismatch }
        if receipt.relativePath != existing.relativePath {
            let redundant = try originalURL(for: receipt.relativePath)
            if files.fileExists(atPath: redundant.path) { try files.removeItem(at: redundant) }
        }
        try finish(receipt)
    }
    func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func copyAndHash(from source: URL, to destination: URL) throws -> (hash: String, size: Int64) {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard files.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
            hasher.update(data: chunk)
            size += Int64(chunk.count)
        }
        try output.synchronize()
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }
    private func validate(_ url: URL, expectedType: UTType) throws -> String {
        if expectedType.conforms(to: .pdf) {
            guard let pdf = CGPDFDocument(url as CFURL), pdf.isEncrypted || pdf.numberOfPages > 0 else { throw ArchiveError.invalidDocument }
            return UTType.pdf.identifier
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              let actual = UTType(identifier), actual.conforms(to: expectedType),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 32,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) != nil else { throw ArchiveError.invalidDocument }
        return identifier
    }

    func prepareOpenCopy(_ document: HouseholdDocument) async throws -> URL {
        let original = try await localOriginal(for: document)
        let directory = files.temporaryDirectory.appendingPathComponent("StowKit-Open/\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(URL(fileURLWithPath: document.originalFilename).lastPathComponent)
        try files.copyItem(at: original, to: url)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}


enum OriginalAccessError: LocalizedError {
    case missing
    var errorDescription: String? {
        "The archived original is missing from this Mac. Connect this archive to iCloud or restore the original from your backup."
    }
}
