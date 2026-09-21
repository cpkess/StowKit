import Foundation

/// StowKit has one archive: the one in the owner's iCloud. This decides, at launch, how this
/// Mac's local archive relates to it. The decision is pure so every branch is testable; the
/// caller gathers the facts and carries out the result.
enum ArchiveResolution: Equatable {
    /// Already bound to its iCloud zone, or the zone exists for this archive: sync it.
    case connect
    /// No iCloud archive exists yet. An empty archive moves up silently; one holding documents
    /// asks first, because enabling iCloud uploads everything in it.
    case upload(ask: Bool)
    /// This Mac's archive is empty and the account already has one: use that one.
    case join(CloudArchiveBinding)
    /// Stay local and say why. Never a silent merge or a guess between archives.
    case stayLocal(String)
}

struct ArchiveFacts {
    var localArchiveID: UUID
    var documentCount: Int
    /// The stored binding and whether it is enabled; nil when this archive never used iCloud.
    var binding: (CloudArchiveBinding, Bool)?
    var pausedByOwner: Bool
    /// The account's own StowKit zones. Shared households are joined by invitation, not here.
    var privateZones: [CloudArchiveBinding]
}

enum ArchiveResolver {
    static func resolve(_ facts: ArchiveFacts) -> ArchiveResolution {
        if let binding = facts.binding, binding.1 { return .connect }
        if facts.pausedByOwner { return .stayLocal("iCloud is paused.") }
        // A disabled binding was turned off by the pre-1.2 archive switch or account-change bug,
        // not by the owner, whose pauses are recorded separately.
        if facts.binding != nil || facts.privateZones.contains(where: { $0.archiveID == facts.localArchiveID }) { return .connect }
        if facts.privateZones.isEmpty { return .upload(ask: facts.documentCount > 0) }
        if facts.documentCount == 0 {
            if facts.privateZones.count == 1, let zone = facts.privateZones.first { return .join(zone) }
            return .stayLocal("Your iCloud account holds \(facts.privateZones.count) StowKit archives, so StowKit can’t tell which to use.")
        }
        return .stayLocal("This Mac has documents in its own archive, and your iCloud account already holds a different one. Combining archives isn’t built yet, so this Mac stays separate.")
    }
}
