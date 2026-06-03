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

    /// The studio behind DiskGallery.
    static let agencyName = "Smash"
    static let agencyURL = URL(string: "https://smash.mrbarkan.com")!

    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
    /// Beta builds (`DG_BETA`) read "Version 1.0 — Beta 5"; release builds read "Version 1.0 (5)".
    /// The beta number is the build (`CURRENT_PROJECT_VERSION`), bumped each beta.
    static var versionLine: String {
        #if BETA
        "Version \(shortVersion) — Beta \(build)"
        #else
        "Version \(shortVersion) (\(build))"
        #endif
    }
    /// "Version 1.0 — Beta 5 · macOS 15+ · Read-only"
    static var splashVersionLine: String { "\(versionLine) · macOS 15+ · Read-only" }
}
