import Foundation

/// Brand/version facts shared by the splash and About windows, sourced from the bundle
/// so they track `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in project.yml.
enum AppInfo {
    static let tagline = "It's like Maps, but for your drives."
    static let aboutTagline = "A read-only catalog for your external drives — browsable even when they're unplugged."
    static let copyright = "© 2026 dbarkan · All rights reserved."
    static let readOnlyNote = "Cataloging is strictly read-only — only the Finder tags you apply are written to a drive."
    static let catalogPath = "~/Library/…/DiskGallery/catalog.sqlite"
    static let website = URL(string: "https://diskgallery.app")!

    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
    /// "Version 1.0 (1)"
    static var versionLine: String { "Version \(shortVersion) (\(build))" }
    /// "Version 1.0 (1) · macOS 15+ · Read-only"
    static var splashVersionLine: String { "\(versionLine) · macOS 15+ · Read-only" }
}
