import SwiftUI

/// Inbox as a flow: one document at a time, a suggestion to take in one keystroke, one-click
/// filing into any collection, and the next document opening after each decision.
struct InboxReview {
    let position: Int
    let count: Int
    let analysis: AnalysisSnapshot?
    let accept: () -> Void
    let file: (String) -> Void
    let done: () -> Void
    let next: (() -> Void)?
    let previous: (() -> Void)?
}

struct InboxReviewCard: View {
    let review: InboxReview
    let collections: [LibraryCollection]

    private var suggestion: DocumentUnderstanding? { review.analysis?.result }
    private var waiting: Bool { ["queued", "analyzing", "waitingText"].contains(review.analysis?.state) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("Inbox · \(review.position) of \(review.count)", systemImage: "tray").font(.subheadline.weight(.semibold))
                Spacer()
                Button { review.previous?() } label: { Image(systemName: "chevron.left") }
                    .disabled(review.previous == nil).help("Previous (⌘[)").keyboardShortcut("[", modifiers: .command)
                Button { review.next?() } label: { Image(systemName: "chevron.right") }
                    .disabled(review.next == nil).help("Skip to Next (⌘])").keyboardShortcut("]", modifiers: .command)
            }.buttonStyle(.borderless)

            if let suggestion, !suggestion.title.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Suggested").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        if !suggestion.collection.isEmpty {
                            Text(suggestion.collection).font(.caption.weight(.semibold))
                                .padding(.horizontal, 7).padding(.vertical, 2).background(.tint.opacity(0.15), in: Capsule())
                        }
                        Text(UnderstandingInspector.certainty(suggestion.confidence)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(suggestion.title).font(.subheadline).lineLimit(2)
                    if !suggestion.correspondent.isEmpty {
                        Text(suggestion.correspondent).font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Use Suggestions & Next", action: review.accept)
                        .keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent)
                        .help("Fill in the suggested details, file it, mark it reviewed, and open the next document (⌘↩)")
                }
            } else if waiting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading the document for suggestions…").font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("File in").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(collections) { collection in
                        let suggested = collection.name == suggestion?.collection
                        Button { review.file(collection.name) } label: {
                            Label(collection.name, systemImage: collection.symbol).font(.caption)
                        }
                        .buttonStyle(.bordered).tint(suggested ? .accentColor : nil)
                        .help("File in \(collection.name), mark reviewed, and open the next document")
                    }
                }
            }
            Button("Mark Reviewed & Next", action: review.done)
                .keyboardShortcut(.return, modifiers: [.command, .option])
                .help("Keep the details as they are, mark it reviewed, and open the next document (⌥⌘↩)")
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Wraps its children onto as many rows as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(width: proposal.width ?? .infinity, subviews).last.map { CGSize(width: proposal.width ?? $0.width, height: $0.maxY) } ?? .zero
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
    private func rows(width: CGFloat, _ subviews: Subviews) -> [(width: CGFloat, maxY: CGFloat)] {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        var result: [(width: CGFloat, maxY: CGFloat)] = []
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += rowHeight + spacing; x = 0; rowHeight = 0 }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height); widest = max(widest, x - spacing)
            result.append((widest, y + rowHeight))
        }
        return result
    }
}
