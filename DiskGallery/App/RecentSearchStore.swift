import Foundation
import Observation

/// A persisted recent search: the query, its last result count, and when it ran.
struct StoredRecentSearch: Codable, Identifiable, Equatable {
    var query: String
    var count: Int
    var date: Date
    var id: String { query }
}

/// Recent searches persisted across launches in UserDefaults. Newest first, de-duped by
/// query, capped. Mirrors the other small app stores (ShortcutStore/ThemeStore).
@MainActor
@Observable
final class RecentSearchStore {
    private static let key = "recentSearches.v1"
    private static let cap = 8

    private(set) var items: [StoredRecentSearch]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([StoredRecentSearch].self, from: data) {
            items = decoded
        } else {
            items = []
        }
    }

    /// Records a search, moving an existing same-query entry to the front with fresh count/date.
    func record(query: String, count: Int) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        items.removeAll { $0.query == trimmed }
        items.insert(StoredRecentSearch(query: trimmed, count: count, date: Date()), at: 0)
        if items.count > Self.cap { items = Array(items.prefix(Self.cap)) }
        persist()
    }

    func clear() {
        items = []
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
