import SwiftUI
import DiskGalleryCore

/// Modern Search page (mockup `.page--search`): a centered glass hero with the big query field,
/// scope chips, and a Recent list — below the permanent OLED. Typing runs the real FTS search and
/// shows results. Scopes are real (all drives / a specific volume). Recent is real in-session
/// history (counts come from the live result set); persistence is in the future-sprint backlog.
struct ModernSearchPage: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme

    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var scope: SearchScope = .all
    @State private var scopeLabel = "All drives"
    @State private var filter: SearchFilter = .none
    @FocusState private var focused: Bool

    private var accent: Color { env.theme.accent.palette.accent }
    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }
    private var showResults: Bool { trimmed.count >= 2 || filter != .none }

    var body: some View {
        ModernPageScaffold(leadingIcon: "magnifyingglass", crumbs: ["Search"]) {
            Group {
                if showResults {
                    VStack(spacing: 14) {
                        heroCard(fullWidth: true)
                        resultsCard
                    }
                } else {
                    heroCard(fullWidth: false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: showResults ? .top : .center)
        }
        .task(id: query + "|" + scopeLabel + "|" + String(describing: filter)) { await runSearch() }
        .onAppear { focused = true }
    }

    // MARK: Hero
    private func heroCard(fullWidth: Bool) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(accent)
                        Text("Search all drives").font(.system(size: 13, weight: .bold)).foregroundStyle(DGToken.ink(scheme))
                    }
                    Text("Catalog stays searchable even when drives are offline")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced)).tracking(1.2)
                        .textCase(.uppercase).foregroundStyle(DGToken.ink3(scheme))
                }
                searchField
                scopeChips
                savedSearchChips
                if !showResults { recentSection }
            }
            .padding(EdgeInsets(top: 36, leading: 34, bottom: 30, trailing: 34))
        }
        .frame(maxWidth: fullWidth ? .infinity : 580)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var searchField: some View {
        HStack(spacing: 13) {
            Image(systemName: "magnifyingglass").font(.system(size: 22)).foregroundStyle(accent)
            TextField("Filenames, paths, Finder tags…", text: $query)
                .textFieldStyle(.plain).font(.system(size: 18, weight: .medium))
                .foregroundStyle(DGToken.ink(scheme)).focused($focused)
            Text("⌘K").font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(DGToken.glass2(scheme), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .foregroundStyle(DGToken.ink3(scheme))
        }
        .padding(.horizontal, 20).frame(height: 58)
        .background(DGToken.glass2(scheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(DGToken.hair2(scheme), lineWidth: 1))
    }

    private var scopeChips: some View {
        let scopes = ["All drives"] + env.volumeSummaries.map(\.name)
        return FlowChips(labels: scopes, selected: scopeLabel) { label in
            scopeLabel = label
            if label == "All drives" {
                scope = .all
            } else if let v = env.volumeSummaries.first(where: { $0.name == label }), let sid = v.latestSnapshotId {
                scope = .volumeLatest(sid)
            } else {
                scope = .all
            }
        }
    }

    /// The saved searches the mockup hints at, each a real predicate.
    private var savedSearches: [(label: String, filter: SearchFilter)] {
        [("Photos · RAW", .category(.photos)),
         ("Duplicates only", .duplicatesOnly),
         ("Tagged: Delete", .tagged(.delete))]
    }

    private var savedSearchChips: some View {
        HStack(spacing: 7) {
            ForEach(savedSearches, id: \.label) { item in
                ModernFilterChip(label: item.label, selected: filter == item.filter) {
                    filter = (filter == item.filter) ? .none : item.filter
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SecHeader(title: "Recent")
                if !env.recentSearches.items.isEmpty {
                    Button("Clear") { env.recentSearches.clear() }
                        .buttonStyle(.plain)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(accent)
                }
            }
            if env.recentSearches.items.isEmpty {
                Text("No recent searches yet").font(.system(size: 13)).foregroundStyle(DGToken.ink3(scheme))
                    .padding(.vertical, 9)
            } else {
                ForEach(Array(env.recentSearches.items.enumerated()), id: \.element.id) { idx, r in
                    Button { query = r.query } label: {
                        HStack(spacing: 11) {
                            Image(systemName: "clock").font(.system(size: 15)).foregroundStyle(DGToken.ink3(scheme))
                            Text(r.query).font(.system(size: 13)).foregroundStyle(DGToken.ink2(scheme)).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(Format.count(r.count)).font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(DGToken.ink3(scheme))
                        }
                        .padding(.vertical, 9).padding(.horizontal, 6)
                        .overlay(alignment: .bottom) {
                            if idx < env.recentSearches.items.count - 1 { Rectangle().fill(DGToken.hair(scheme)).frame(height: 1) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Results
    private var resultsCard: some View {
        GlassCard {
            VStack(spacing: 0) {
                ModernCardHeader(systemImage: "magnifyingglass", title: "Results",
                                 meta: "\(Format.count(results.count)) match\(results.count == 1 ? "" : "es")", accent: accent)
                List {
                    ForEach(results) { r in
                        SearchResultRow(result: r, accent: accent)
                            .listRowInsets(EdgeInsets(top: 1, leading: 12, bottom: 1, trailing: 18))
                            .listRowSeparator(.hidden).listRowBackground(Color.clear)
                    }
                    if results.isEmpty {
                        Text("No matches for “\(trimmed)”").font(.system(size: 13)).foregroundStyle(DGToken.ink3(scheme))
                            .listRowSeparator(.hidden).listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func runSearch() async {
        guard trimmed.count >= 2 || filter != .none else { results = []; return }
        let found = (try? await env.catalog.search.search(trimmed, scope: scope, filter: filter)) ?? []
        results = found
        if trimmed.count >= 2 { env.recentSearches.record(query: trimmed, count: found.count) }
    }
}

/// Wrapping row of filter chips (scopes can exceed one line).
private struct FlowChips: View {
    let labels: [String]
    let selected: String
    let onSelect: (String) -> Void
    var body: some View {
        // A simple two-axis wrap good enough for a handful of drives.
        let columns = [GridItem(.adaptive(minimum: 92, maximum: 220), spacing: 8, alignment: .leading)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(labels, id: \.self) { label in
                ModernFilterChip(label: label, selected: selected == label) { onSelect(label) }
            }
        }
    }
}

private struct SearchResultRow: View {
    @Environment(\.colorScheme) private var scheme
    let result: SearchResult
    let accent: Color

    private var subtitle: String {
        let parent = (result.relPath as NSString).deletingLastPathComponent
        let path = parent.isEmpty ? "/" : "/" + parent
        return "\(result.volumeName) · \(path)"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: result.isDir ? "folder.fill" : "doc").font(.system(size: 18)).frame(width: 20)
                .foregroundStyle(result.isDir ? accent : DGToken.ink3(scheme))
            VStack(alignment: .leading, spacing: 3) {
                Text(result.name).font(.system(size: 13.5, weight: .medium)).foregroundStyle(DGToken.ink(scheme))
                    .lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.system(size: 9, design: .monospaced)).foregroundStyle(DGToken.ink3(scheme))
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Format.bytes(result.displaySize)).font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(DGToken.ink2(scheme)).frame(minWidth: 66, alignment: .trailing)
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .contentShape(Rectangle())
    }
}
