import SwiftUI
import DiskGalleryCore

struct SearchResultsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var query = ""
    @State private var results: [SearchResult] = []

    var body: some View {
        List(results) { result in
            HStack(spacing: 8) {
                Image(systemName: result.isDir ? "folder.fill" : "doc")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.name).lineLimit(1)
                    Text("\(result.volumeName) · \(result.relPath)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(Format.bytes(result.displaySize)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, placement: .toolbar, prompt: "Search file and folder names")
        .overlay {
            if results.isEmpty {
                ContentUnavailableView(query.isEmpty ? "Search your archives" : "No matches",
                                       systemImage: "magnifyingglass",
                                       description: Text(query.isEmpty
                                                         ? "Find files and folders across every cataloged drive — even disconnected ones."
                                                         : "Nothing matches “\(query)”."))
            }
        }
        .task(id: query) { await run() }
    }

    private func run() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { results = []; return }
        results = (try? await env.catalog.search.search(trimmed)) ?? []
    }
}
