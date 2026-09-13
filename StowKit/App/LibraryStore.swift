import SwiftUI
import Observation

@MainActor @Observable
final class LibraryStore {
    var documents = SampleLibrary.documents()
    var destination: LibraryDestination? = .recent
    var selection: UUID?
    var search = ""
    var previewError: String?
    var collections = LibraryCollection.defaults
    var newestFirst = true
    private var prepared = false

    init() { selection = documents.first?.id }

    var visibleDocuments: [HouseholdDocument] {
        documents.filter { document in
            let matchesDestination: Bool = switch destination {
            case .inbox: document.needsReview
            case .favorites: document.favorite
            case .collection(let name): document.collections.contains(name)
            default: true
            }
            let terms = search.split(whereSeparator: \.isWhitespace)
            return matchesDestination && terms.allSatisfy { document.searchableText.localizedStandardContains(String($0)) }
        }.sorted { newestFirst ? $0.importedAt > $1.importedAt : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func reconcileSelection() {
        if !visibleDocuments.contains(where: { $0.id == selection }) {
            selection = visibleDocuments.first?.id
        }
    }

    func preparePreviews() async {
        guard !prepared else { return }
        prepared = true
        // AppKit fixture rendering requires the main actor. These eight one-page samples
        // are tiny; the production importer must perform file and OCR work off-main.
        await Task.yield()
        do {
            let urls = try SampleLibrary.makePreviews(for: documents)
            for index in documents.indices { documents[index].previewURL = urls[documents[index].id] }
        } catch { previewError = error.localizedDescription }
    }

    func toggleFavorite(_ id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].favorite.toggle()
    }
}
