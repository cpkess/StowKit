import SwiftUI

struct UnderstandingInspector: View {
    let snapshot: AnalysisSnapshot?
    let isTrashed: Bool
    let retry: () -> Void
    let apply: () -> Void
    @State private var showSuggestions = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if snapshot?.state == "analyzing" { ProgressView().controlSize(.small) }
                Text(label).font(.subheadline.weight(.medium))
                Spacer()
                if snapshot?.result != nil { Button("Suggestions") { showSuggestions = true } }
                if snapshot?.state == "complete" || snapshot?.state == "failed" {
                    Button("Analyze Again", action: retry).disabled(isTrashed)
                }
            }
            if let result = snapshot?.result {
                Text("\(result.provider) · \(result.confidence >= 0.90 ? "High confidence" : result.confidence >= 0.65 ? "Medium confidence" : "Low confidence")")
                    .font(.caption).foregroundStyle(.secondary)
                if !result.note.isEmpty { Text(result.note).font(.caption).foregroundStyle(.secondary) }
            }
            if let error = snapshot?.error { Text(error).font(.caption).foregroundStyle(.secondary) }
        }.sheet(isPresented: $showSuggestions) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Suggested Details").font(.title2.weight(.semibold))
                if let result = snapshot?.result {
                    LabeledContent("Title", value: result.title.isEmpty ? "No suggestion" : result.title)
                    LabeledContent("Collection", value: result.collection.isEmpty ? "No suggestion" : result.collection)
                    LabeledContent("Correspondent", value: result.correspondent.isEmpty ? "No suggestion" : result.correspondent)
                    LabeledContent("Tags", value: result.tags.joined(separator: ", "))
                    Text(result.summary).textSelection(.enabled)
                    if !result.evidence.isEmpty { Text("Evidence: “\(result.evidence)”").font(.caption).textSelection(.enabled) }
                    Text("Applying uses the nonempty suggestions, adds the collection, and marks this document reviewed. It can replace your edited title, summary, correspondent, and tags.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Cancel") { showSuggestions = false }
                        Spacer()
                        Button("Apply Suggestions") { apply(); showSuggestions = false }.disabled(isTrashed || result.title.isEmpty)
                    }
                }
            }.padding(24).frame(width: 520)
        }
    }
    private var label: String {
        switch snapshot?.state {
        case "analyzing": "Understanding document…"
        case "complete": "Document understanding"
        case "failed": "Analysis needs attention"
        case "paused": "Analysis paused in Trash"
        case "queued": "Waiting to analyze"
        default: "Analysis follows text extraction"
        }
    }
}
