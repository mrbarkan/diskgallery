import SwiftUI
import AppKit
import DiskGalleryCore

@main
enum Launcher {
    static func main() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--scan"), index + 1 < args.count {
            HeadlessScan.run(path: args[index + 1])   // performs the scan and exits
        }
        DiskGalleryApp.main()
    }
}

/// Headless catalog scan: `DiskGallery --scan /path/to/drive`. Scans into the
/// default catalog and exits. Handy for scripting and verification.
enum HeadlessScan {
    static func run(path: String) -> Never {
        let url = URL(fileURLWithPath: path)
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let catalog = try Catalog.makeDefault()
                for try await progress in catalog.scanner.scan(volumeURL: url) where progress.isComplete {
                    print("Cataloged \(progress.filesSeen) files (\(Format.bytes(progress.bytesSeen))) from \(path)")
                }
            } catch {
                FileHandle.standardError.write(Data("Scan failed: \(error)\n".utf8))
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }
}

struct DiskGalleryApp: App {
    @State private var env: AppEnvironment? = try? AppEnvironment()
    @State private var systemAppearance = SystemAppearance()

    var body: some Scene {
        WindowGroup {
            if let env {
                ContentView()
                    .environment(env)
                    .task {
                        env.installKeyboardMonitor()
                        await env.refresh()
                        if env.selection == nil {
                            env.selection = env.volumeSummaries.first.map { SidebarItem.volume($0.id) }
                        }
                    }
            } else {
                ContentUnavailableView("Couldn't open the catalog",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text("The DiskGallery database could not be created."))
            }
        }
        .windowToolbarStyle(.unified)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(after: .newItem) {
                Divider()
                Button("Export Library…") { env?.exportLibrary() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Import Library…") { env?.importLibrary() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }

        Settings {
            if let env {
                SettingsView()
                    .environment(env)
                    .preferredColorScheme(env.theme.mode.resolvedScheme(systemAppearance))
            }
        }
    }
}

struct ContentView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var systemAppearance = SystemAppearance()

    var body: some View {
        Group {
            if modern { modernSplit } else { classicSplit }
        }
        .background { if modern { SpatialBackdrop(palette: env.theme.accent.palette) } }
        .modernWindowChrome(modern)
        .sheet(isPresented: Binding(get: { env.activeScan != nil }, set: { _ in })) {
            ScanProgressView()
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { env.errorMessage != nil },
                                    set: { if !$0 { env.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(env.errorMessage ?? "")
        }
        .tint(env.theme.accent.palette.accent)
        .preferredColorScheme(effectiveScheme)
        .frame(minWidth: 1040, minHeight: 680)
    }

    /// Resolve "System" to a concrete scheme so Modern tokens & glass materials stay in
    /// sync (a nil preferredColorScheme renders a mixed light/dark UI in this app).
    private var effectiveScheme: ColorScheme { env.theme.mode.resolvedScheme(systemAppearance) }

    // Classic — the original three-column layout, unchanged.
    private var classicSplit: some View {
        NavigationSplitView {
            LibrarySidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } content: {
            ContentColumn()
                .navigationSplitViewColumnWidth(min: 360, ideal: 480)
        } detail: {
            EntryDetailView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        }
    }

    // Modern — two floating glass panes over the spatial backdrop (the mockup's
    // `grid-template-columns: 272px 1fr; gap:14; padding:14`). A custom HStack rather
    // than NavigationSplitView so the panes float with a true gutter (matches mockup).
    private var modernSplit: some View {
        HStack(alignment: .top, spacing: 14) {
            // Drop the sidebar by one topbar row (40 + 14 gap) so its top edge lines up
            // with the OLED, leaving the traffic-light strip clear above it.
            ModernSidebar().frame(width: 272).padding(.top, 54)
            ModernWorkspace().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 14).padding(.bottom, 14).padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    private var modern: Bool { env.theme.skin == .modern }
}

/// Routes the middle column based on the sidebar selection.
struct ContentColumn: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        switch env.selection {
        case .volume(let id):
            if let summary = env.volumeSummaries.first(where: { $0.id == id }) {
                VolumeBrowserView(summary: summary).id(summary.id)
            } else {
                ContentUnavailableView("Drive not found", systemImage: "externaldrive")
            }
        case .duplicates:
            DuplicatesView()
        case .tagged(let tag):
            TaggedListView(tag: tag)
        case .search:
            SearchResultsView()
        case .plan:
            ActionPlanView()
        case .transfer:
            TransferPlannerView()
        case nil:
            ContentUnavailableView("Select a drive",
                                   systemImage: "sidebar.left",
                                   description: Text("Pick a drive, or scan a new one, to browse its catalog."))
        }
    }
}
