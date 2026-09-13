import SwiftUI

struct ProcessingInspector: View {
    let documentID: UUID
    let snapshot: ProcessingSnapshot?
    let service: TextSearchService?
    let isTrashed: Bool
    let retry: (Bool) -> Void
    @State private var showText = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                if snapshot?.state.isActive == true {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: snapshot?.state == .failed ? "exclamationmark.circle" : "text.viewfinder")
                        .foregroundStyle(snapshot?.state == .failed ? Color.orange : Color.secondary)
                }
                Text(snapshot?.progressLabel ?? "Waiting to extract text").font(.subheadline.weight(.medium))
                Spacer()
                Button("View Text") { showText = true }
                    .disabled((snapshot?.completedPages ?? 0) == 0 || service == nil)
                if snapshot?.state == .failed && !isTrashed {
                    Button("Retry") { retry(false) }
                }
                Menu {
                    Button("Extract Again") { retry(true) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Text Extraction Actions")
                    .disabled(snapshot?.state.isActive == true || snapshot?.state == .queued || isTrashed)
            }
            if let snapshot {
                if snapshot.state.isActive && snapshot.pageCount > 0 {
                    ProgressView(value: Double(snapshot.completedPages), total: Double(snapshot.pageCount))
                }
                if let error = snapshot.error {
                    Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if snapshot.completedPages > 0 {
                        Text("Text from \(snapshot.completedPages) completed page(s) is available. Retry resumes at the next page.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if snapshot.state == .complete {
                    Text(snapshot.characterCount == 0
                         ? "No readable text was found. You can still preview, organize, and open this document."
                         : "\(snapshot.pageCount) page(s) · \(snapshot.ocrPages) read with OCR · Processed on this Mac")
                        .font(.caption).foregroundStyle(.secondary)
                } else if snapshot.state == .queued {
                    Text("Your original is available while text extraction waits in the background.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .sheet(isPresented: $showText) {
            ExtractedTextView(documentID: documentID, snapshot: snapshot, service: service)
        }
    }
}

private struct ExtractedTextView: View {
    let documentID: UUID
    let snapshot: ProcessingSnapshot?
    let service: TextSearchService?
    @Environment(\.dismiss) private var dismiss
    @State private var pages: [ExtractedTextPage] = []
    @State private var loading = true
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extracted Text").font(.title2.weight(.semibold))
                    Text("OCR may contain mistakes. The original document is unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pages.map(\.text).joined(separator: "\n\n"), forType: .string)
                }.disabled(pages.isEmpty)
            }
            if let failure {
                ContentUnavailableView("Text Unavailable", systemImage: "exclamationmark.circle", description: Text(failure))
            } else if loading {
                ProgressView("Loading Text…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(pages) { page in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Page \(page.index + 1) · \(page.method == .embedded ? "PDF text" : "OCR")")
                                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                Text(page.text.isEmpty ? "No text found on this page." : page.text)
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                Divider()
                            }
                        }
                    }.padding(12)
                }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            }
            HStack {
                if snapshot?.state != .complete { Text("Showing completed pages. More text may become available.").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 660, height: 560)
        .task(id: snapshot?.updatedAt) {
            guard let service else { loading = false; failure = "The text store is unavailable."; return }
            do {
                let loaded = try await service.pages(for: documentID)
                guard !Task.isCancelled else { return }
                pages = loaded; loading = false; failure = nil
            } catch { if !Task.isCancelled { failure = error.localizedDescription; loading = false } }
        }
    }
}
