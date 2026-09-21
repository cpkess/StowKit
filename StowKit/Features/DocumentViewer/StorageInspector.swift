import SwiftUI

/// Where this document's original lives, and the two controls over it. Removing a download is
/// deliberately worded as removing a copy, not deleting a document: the original is immutable
/// and verified in iCloud, and it comes back on request.
struct StorageInspector: View {
    let state: DocumentStorageState?
    let error: String?
    let isTrashed: Bool
    let setPinned: (Bool) -> Void
    let removeDownload: () -> Void

    private var summary: (symbol: String, title: String, detail: String)? {
        switch state?.location {
        case .availableOffline:
            ("internaldrive", "Stored on this Mac",
             "The original is here and opens without a download.")
        case .optimized:
            ("icloud", "Stored in iCloud",
             "Details, text, and search stay on this Mac. The original downloads when you open it.")
        case .cloudOnly:
            ("icloud.slash", "Not downloaded yet",
             "This document arrived from iCloud and its original has not been fetched.")
        case nil: nil
        }
    }

    var body: some View {
        if let summary, let state {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: summary.symbol).foregroundStyle(.secondary)
                    Text(summary.title).font(.subheadline.weight(.medium))
                    Spacer()
                    if state.location == .availableOffline && !isTrashed {
                        Button("Remove Download", action: removeDownload)
                    }
                }
                Text(summary.detail).font(.caption).foregroundStyle(.secondary)
                Toggle("Keep Downloaded", isOn: Binding(get: { state.pinned }, set: setPinned))
                    .toggleStyle(.checkbox).font(.caption).disabled(isTrashed)
                if let error {
                    Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }
}
