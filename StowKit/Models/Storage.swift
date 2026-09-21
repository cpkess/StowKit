import Foundation

/// Measured disk usage for one archive root, in allocated bytes so the total matches `du`.
/// Recorded document sizes are deliberately not used here: they count documents, not disk,
/// and they include trashed and never-downloaded remote originals.
struct ArchiveUsage: Sendable, Equatable {
    var originals: Int64 = 0
    var originalFiles = 0
    var thumbnails: Int64 = 0
    var searchIndex: Int64 = 0
    var database: Int64 = 0
    var staging: Int64 = 0
    var transfers: Int64 = 0
    var other: Int64 = 0
    var unreadable = 0

    /// Interrupted imports and in-flight cloud transfers: transient working space.
    var inProgress: Int64 { staging + transfers }
    var total: Int64 { originals + thumbnails + searchIndex + database + inProgress + other }
    /// Everything that is not an original is derived, and regenerates or resyncs on demand.
    var derived: Int64 { total - originals }
}

/// Where a document's original currently lives. Derived on demand from the filesystem and
/// cloud state; never stored, so it cannot drift out of agreement with the disk.
enum OriginalLocation: Sendable, Equatable {
    /// The original is on this Mac.
    case availableOffline
    /// No original here, but the thumbnail and text remain and the bytes can be fetched back.
    case optimized
    /// Nothing local beyond metadata — a remote document never downloaded.
    case cloudOnly
}

/// What the inspector shows for one document's original.
struct DocumentStorageState: Sendable, Equatable {
    let documentID: UUID
    let location: OriginalLocation
    let pinned: Bool
    /// Whether this archive can hand originals back to iCloud at all: sync on, writable, not
    /// suspended, and owned. When false the controls would only ever be refused, so they hide.
    let manageable: Bool
}

/// Repository-owned facts that decide whether a local original may be removed.
/// Gathered on the main actor and handed to `DocumentStorageManager`, which is the single
/// place that decides. Callers never interpret these fields themselves.
struct EvictionFacts: Sendable, Equatable {
    var pinned = true
    var cloudVerified = false
    var remote = false
    var processingOutstanding = true
    var sharedArchive = true

    /// Uploaded and independently verified, or downloaded — a download validates chunk and
    /// whole-file SHA-256 before promoting, so a present local copy is itself the evidence.
    var hasVerifiedCloudCopy: Bool { cloudVerified || remote }
}

/// Why an eviction was refused. Every case is a safety invariant from
/// `docs/STORAGE_ARCHITECTURE.md`, and each one is asserted by a test.
enum EvictionRefusal: LocalizedError, Equatable {
    case pinned
    case noVerifiedCloudCopy
    case processingOutstanding
    case syncUnavailable
    case sharedArchive
    case noThumbnail
    case transferInProgress
    case notDownloaded

    var errorDescription: String? {
        switch self {
        case .pinned: "This document is kept on this Mac. Turn off Keep Downloaded first."
        case .noVerifiedCloudCopy: "StowKit has not verified a copy of this original in iCloud yet."
        case .processingOutstanding: "Text extraction still needs the original."
        case .syncUnavailable: "iCloud is off, so this Mac holds the only copy."
        case .sharedArchive: "Shared archives keep their downloads; access could be revoked."
        case .noThumbnail: "StowKit has no saved thumbnail for this document yet."
        case .transferInProgress: "A transfer for this document is already running."
        case .notDownloaded: "This original is not stored on this Mac."
        }
    }
}
