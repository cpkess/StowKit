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
