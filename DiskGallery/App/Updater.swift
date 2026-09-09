import Sparkle

/// Sparkle updater, started at launch so scheduled background checks run.
/// `Updater.shared.updater.checkForUpdates()` drives the menu item.
@MainActor
enum Updater {
    static let shared = SPUStandardUpdaterController(startingUpdater: true,
                                                     updaterDelegate: nil,
                                                     userDriverDelegate: nil)
}
