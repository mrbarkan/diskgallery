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
    @State private var betaGate = BetaGate()
    @State private var systemAppearance = SystemAppearance()
    @State private var launching = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                if betaGate.isExpired {
                    BetaExpiredView()
                } else if let env {
                    ContentView().environment(env)
                } else {
                    ContentUnavailableView("Couldn't open the catalog",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text("The DiskGallery database could not be created."))
                }
                if launching {
                    SplashView().transition(.opacity)
                }
            }
            .task {
                // Open the catalog, then fade the splash after a brief beat.
                if let env {
                    env.installKeyboardMonitor()
                    await env.refresh()
                    env.startHardwareCapture()
                    if env.selection == nil {
                        env.selection = env.restoredLaunchSelection()
                    }
                }
                try? await Task.sleep(for: .milliseconds(550))
                withAnimation(.easeOut(duration: 0.5)) { launching = false }
            }
        }
        .windowToolbarStyle(.unified)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)   // let the window grow to fill the screen / maximize
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutMenuItem()
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Export Library…") {
                    if env?.license.isUnlocked(.exportImport) == true { env?.exportLibrary() }
                    else { env?.requestUpgrade(.exportImport) }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Import Library…") {
                    if env?.license.isUnlocked(.exportImport) == true { env?.importLibrary() }
                    else { env?.requestUpgrade(.exportImport) }
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }

        // Custom branded About panel (replaces the system one).
        Window("About DiskGallery", id: "about") {
            AboutView(licensedTo: aboutLicensee, license: aboutLicense)
                .fixedSize()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)

        Settings {
            if let env {
                SettingsView()
                    .environment(env)
                    .preferredColorScheme(env.theme.mode.resolvedScheme(systemAppearance))
            }
        }
    }

    // License block for the About window, derived from the offline license state.
    private var aboutLicensee: String {
        switch env?.license.status {
        case .licensed(let email):  return email
        case .free:                 return "Free"
        case .unconfigured, .none:  return "—"
        }
    }
    private var aboutLicense: String {
        switch env?.license.status {
        case .licensed:             return "Pro · Perpetual"
        case .free:                 return "Free"
        case .unconfigured, .none:  return "Unlicensed"
        }
    }
}

/// The "About DiskGallery" menu item — opens the branded About window.
private struct AboutMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("About DiskGallery") { openWindow(id: "about") }
    }
}

struct ContentView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var systemAppearance = SystemAppearance()

    var body: some View {
        NavigationSplitView {
            LibrarySidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } content: {
            ContentColumn()
                .navigationSplitViewColumnWidth(min: 360, ideal: 480)
        } detail: {
            detailColumn
                .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        }
        .toolbar(id: "dg.main") { MainToolbar(env: env) }
        .overlay(alignment: .top) {
            if let progress = env.thumbnailProgress {
                PreviewProgressBanner(progress: progress) { env.cancelThumbnails() }
            }
        }
        .sheet(item: Binding(get: { env.changesVolume },
                             set: { env.changesVolume = $0 })) { summary in
            ChangesView(summary: summary).environment(env)
        }
        .sheet(isPresented: Binding(get: { env.activeScan != nil }, set: { _ in })) {
            ScanProgressView()
        }
        .sheet(item: Binding(get: { env.executionPrompt }, set: { env.executionPrompt = $0 })) { prompt in
            ExecutionConfirmView(prompt: prompt).environment(env)
        }
        .sheet(isPresented: Binding(get: { env.executionProgress != nil }, set: { _ in })) {
            if let p = env.executionProgress { ExecutionProgressView(progress: p).environment(env) }
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { env.errorMessage != nil },
                                    set: { if !$0 { env.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(env.errorMessage ?? "")
        }
        .sheet(item: Binding(get: { env.upgradeFeature.map { FeatureBox($0) } },
                             set: { env.upgradeFeature = $0?.feature })) { box in
            UpgradeSheet(feature: box.feature)
                .environment(env)
        }
        .tint(env.theme.accent.palette.accent)
        .preferredColorScheme(env.theme.mode.resolvedScheme(systemAppearance))
        .frame(minWidth: 1040, minHeight: 680)
    }

    /// The detail column shows the All Drives copy-comparison when that view is active,
    /// otherwise the standard entry detail.
    @ViewBuilder private var detailColumn: some View {
        if case .allDrives = env.selection {
            if let node = env.selectedUnifiedNode {
                ScrollView { UnifiedComparePanel(node: node) }
            } else {
                ContentUnavailableView("Compare copies", systemImage: "rectangle.on.rectangle",
                                       description: Text("Select an item to compare its copies across drives."))
            }
        } else {
            EntryDetailView()
        }
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
            TaggedListView(initialFilter: tag == .none ? nil : tag)
        case .search:
            SearchResultsView()
        case .plan, .transfer:
            OrganizeHomeView()        // legacy sidebar items — map to the Organize home
        case .organize:
            OrganizeHomeView()
        case .allDrives:
            AllDrivesView()
        case .gallery:
            GalleryView()
        case nil:
            ContentUnavailableView("Select a drive",
                                   systemImage: "sidebar.left",
                                   description: Text("Pick a drive, or scan a new one, to browse its catalog."))
        }
    }
}

/// Wraps a `Feature` so it can drive a `.sheet(item:)`.
struct FeatureBox: Identifiable { let feature: Feature; var id: String { feature.rawValue }
    init(_ feature: Feature) { self.feature = feature } }
