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

        Settings {
            if let env {
                SettingsView()
                    .environment(env)
                    .preferredColorScheme(env.theme.mode.colorScheme)
            }
        }
    }
}

struct ContentView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
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
        .sheet(isPresented: Binding(get: { env.activeScan != nil },
                                    set: { if !$0 { env.cancelScan() } })) {
            ScanProgressView()
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { env.errorMessage != nil },
                                    set: { if !$0 { env.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(env.errorMessage ?? "")
        }
        .tint(env.theme.theme.accent)
        .preferredColorScheme(env.theme.mode.colorScheme)
    }
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
        case nil:
            ContentUnavailableView("Select a drive",
                                   systemImage: "sidebar.left",
                                   description: Text("Pick a drive, or scan a new one, to browse its catalog."))
        }
    }
}
