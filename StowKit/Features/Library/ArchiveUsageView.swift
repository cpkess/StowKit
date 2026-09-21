import SwiftUI

/// Reports measured disk usage for the active archive. Measurement is explicit: walking the
/// archive is not free, and a number that silently went stale would be worse than none.
struct ArchiveUsageView: View {
    @Bindable var library: LibraryStore

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    var body: some View {
        Group {
            if let usage = library.usage {
                LabeledContent("Disk used", value: bytes(usage.total))
                LabeledContent("Originals", value: "\(bytes(usage.originals)) · \(usage.originalFiles) file(s)")
                LabeledContent("Database", value: bytes(usage.database))
                LabeledContent("Search index", value: bytes(usage.searchIndex))
                LabeledContent("Thumbnails", value: bytes(usage.thumbnails))
                if usage.inProgress > 0 {
                    LabeledContent("In progress", value: bytes(usage.inProgress))
                }
                if usage.otherArchives > 0 {
                    LabeledContent("Other iCloud archives", value: bytes(usage.otherArchives))
                }
                if usage.verificationData > 0 {
                    LabeledContent("iCloud test data", value: bytes(usage.verificationData))
                    Text("Fictional files left by developer iCloud verification runs. They are not your documents.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if usage.other > 0 {
                    LabeledContent("Other", value: bytes(usage.other))
                }
                Text("Originals are kept on this Mac and are never removed automatically. Trash still counts toward this total. Everything outside Originals regenerates or downloads again.")
                    .font(.caption).foregroundStyle(.secondary)
                if usage.unreadable > 0 {
                    Text("\(usage.unreadable) item(s) could not be measured and are not included.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if library.usageError == nil {
                Text("Measure disk use to see how much space this archive occupies.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = library.usageError {
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Button(library.isMeasuringUsage
                   ? "Measuring…" : (library.usage == nil ? "Measure Disk Use" : "Measure Again")) {
                library.refreshUsage()
            }
            .disabled(!library.isReady || library.isMeasuringUsage)
        }
    }
}
