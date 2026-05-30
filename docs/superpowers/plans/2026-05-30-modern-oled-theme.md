# Modern OLED Theme & Selectable Theming — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Classic↔Modern skin switch, a unified accent palette, dark mode, and a CrateDigger-style OLED telemetry display (3 layouts) — all user-selectable in Settings — layered onto DiskGallery's existing 3-column layout.

**Architecture:** Pure, persistence-stable theme enums + migration + capacity math live in `DiskGalleryCore` (unit-testable via the existing `DiskGalleryCoreTests`). The SwiftUI app maps those enums to colors (`AccentPalette`, compiler-exhaustive switch), renders a new `OLEDDisplayView`, and branches the volume browser on the active skin. `ThemeStore` (app, `@Observable`) holds four independent axes persisted to `UserDefaults`.

**Tech Stack:** Swift 6, SwiftUI, macOS 15+, XcodeGen (`xcodegen generate` regenerates the committed `.xcodeproj` after files are added), `xcodebuild` for build/test.

**Spec:** `docs/superpowers/specs/2026-05-30-modern-oled-theme-design.md`

**Conventions for every task:**
- After **creating a new source file**, run `xcodegen generate` so the committed project compiles it, and `git add DiskGallery.xcodeproj` in the commit.
- Build app: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -25`
- Run Core tests: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test 2>&1 | tail -30`
- A single test class adds `-only-testing:DiskGalleryCoreTests/<ClassName>`.

---

## Task 1: Core theme enums + legacy migration

**Files:**
- Create: `DiskGalleryCore/Theme/ThemeModel.swift`
- Test: `DiskGalleryCoreTests/ThemeModelTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// DiskGalleryCoreTests/ThemeModelTests.swift
import XCTest
@testable import DiskGalleryCore

final class ThemeModelTests: XCTestCase {

    func testLegacyThemeMigrationMapsAllKnownValues() {
        XCTAssertEqual(ThemeMigration.accent(fromLegacy: "graphite"), .graphite)
        XCTAssertEqual(ThemeMigration.accent(fromLegacy: "grape"),    .violet)
        XCTAssertEqual(ThemeMigration.accent(fromLegacy: "ocean"),    .blue)
        XCTAssertEqual(ThemeMigration.accent(fromLegacy: "forest"),   .green)
        XCTAssertEqual(ThemeMigration.accent(fromLegacy: "sunset"),   .amber)
        XCTAssertEqual(ThemeMigration.accent(fromLegacy: "rose"),     .coral)
    }

    func testLegacyMigrationDefaultsToVioletForUnknownOrNil() {
        XCTAssertEqual(ThemeMigration.accent(fromLegacy: nil), .violet)
        XCTAssertEqual(ThemeMigration.accent(fromLegacy: ""), .violet)
        XCTAssertEqual(ThemeMigration.accent(fromLegacy: "chartreuse"), .violet)
    }

    func testRawValuesAreStableForPersistence() {
        XCTAssertEqual(Skin.allCases.map(\.rawValue), ["classic", "modern"])
        XCTAssertEqual(Accent.allCases.map(\.rawValue),
                       ["graphite", "violet", "blue", "green", "amber", "coral"])
        XCTAssertEqual(OLEDLayout.allCases.map(\.rawValue), ["telemetry", "gauge", "minimal"])
    }

    func testDisplayNames() {
        XCTAssertEqual(Skin.classic.name, "Classic")
        XCTAssertEqual(Skin.modern.name, "Modern")
        XCTAssertEqual(Accent.violet.name, "Violet")
        XCTAssertEqual(OLEDLayout.telemetry.name, "Telemetry")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test -only-testing:DiskGalleryCoreTests/ThemeModelTests 2>&1 | tail -30`
Expected: compile failure — `cannot find 'ThemeMigration'`, `Skin`, `Accent`, `OLEDLayout` in scope. (First run `xcodegen generate` so the new test file is in the project; it will still fail to compile until Step 3.)

- [ ] **Step 3: Write the implementation**

```swift
// DiskGalleryCore/Theme/ThemeModel.swift
import Foundation

/// Overall visual skin. `classic` is the original look; `modern` adds the OLED
/// telemetry hero and the redesign's accent styling.
public enum Skin: String, CaseIterable, Identifiable, Sendable {
    case classic, modern
    public var id: String { rawValue }
    public var name: String { self == .classic ? "Classic" : "Modern" }
}

/// Unified accent palette shared by both skins. Raw values are persisted — keep stable.
public enum Accent: String, CaseIterable, Identifiable, Sendable {
    case graphite, violet, blue, green, amber, coral
    public var id: String { rawValue }
    public var name: String { rawValue.capitalized }
}

/// Which OLED hero layout the Modern skin shows.
public enum OLEDLayout: String, CaseIterable, Identifiable, Sendable {
    case telemetry, gauge, minimal
    public var id: String { rawValue }
    public var name: String { rawValue.capitalized }
}

/// One-time migration from the pre-redesign `theme` accent names to the unified set.
public enum ThemeMigration {
    /// Maps a legacy stored `theme` value to the new accent. Unknown / nil → `.violet`.
    public static func accent(fromLegacy legacy: String?) -> Accent {
        switch legacy {
        case "graphite": return .graphite
        case "grape":    return .violet
        case "ocean":    return .blue
        case "forest":   return .green
        case "sunset":   return .amber
        case "rose":     return .coral
        default:         return .violet
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodegen generate && xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test -only-testing:DiskGalleryCoreTests/ThemeModelTests 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add DiskGalleryCore/Theme/ThemeModel.swift DiskGalleryCoreTests/ThemeModelTests.swift DiskGallery.xcodeproj
git commit -m "Add Core theme enums (Skin/Accent/OLEDLayout) + legacy migration"
```

---

## Task 2: Core capacity math

**Files:**
- Create: `DiskGalleryCore/Theme/Capacity.swift`
- Test: `DiskGalleryCoreTests/CapacityTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// DiskGalleryCoreTests/CapacityTests.swift
import XCTest
@testable import DiskGalleryCore

final class CapacityTests: XCTestCase {

    func testFractionUsedHalfFull() {
        XCTAssertEqual(Capacity.fractionUsed(total: 100, free: 50), 0.5, accuracy: 0.0001)
    }

    func testFractionUsedClampsAndHandlesUnknown() {
        XCTAssertEqual(Capacity.fractionUsed(total: nil, free: 10), 0)
        XCTAssertEqual(Capacity.fractionUsed(total: 0, free: 0), 0)
        // free > total would imply negative used → clamps to full.
        XCTAssertEqual(Capacity.fractionUsed(total: 100, free: -20), 1, accuracy: 0.0001)
    }

    func testOverCapacityThreshold() {
        XCTAssertFalse(Capacity.isOverCapacity(total: 100, free: 10)) // 90%
        XCTAssertTrue(Capacity.isOverCapacity(total: 100, free: 5))   // 95%
        XCTAssertTrue(Capacity.isOverCapacity(total: 100, free: 0))   // 100%
        XCTAssertFalse(Capacity.isOverCapacity(total: nil, free: nil))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test -only-testing:DiskGalleryCoreTests/CapacityTests 2>&1 | tail -30`
Expected: compile failure — `cannot find 'Capacity' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// DiskGalleryCore/Theme/Capacity.swift
import Foundation

/// Pure drive-fullness math, shared by capacity bars and the OLED display.
public enum Capacity {
    /// Fraction of a drive that is used, clamped to 0...1. Returns 0 when capacity is unknown.
    public static func fractionUsed(total: Int64?, free: Int64?) -> Double {
        guard let total, total > 0 else { return 0 }
        let used = max(0, total - (free ?? 0))
        return min(1, Double(used) / Double(total))
    }

    /// Whether the drive is at/above `threshold` full (default 95%).
    public static func isOverCapacity(total: Int64?, free: Int64?, threshold: Double = 0.95) -> Bool {
        guard let total, total > 0 else { return false }
        return fractionUsed(total: total, free: free) >= threshold
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test -only-testing:DiskGalleryCoreTests/CapacityTests 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add DiskGalleryCore/Theme/Capacity.swift DiskGalleryCoreTests/CapacityTests.swift DiskGallery.xcodeproj
git commit -m "Add Core capacity-fraction / over-capacity helpers"
```

---

## Task 3: App accent palette layer

Maps `Accent` → SwiftUI colors (compiler-exhaustive), adds a `Color(hex:)` helper, and the fixed OLED screen tokens. No unit test (SwiftUI in the app target has no test host); the exhaustive `switch` is compiler-enforced and a build is the verification.

**Files:**
- Modify: `DiskGallery/Support/Colors.swift` (add `Color(hex:)`)
- Create: `DiskGallery/Support/AccentPalette.swift`

- [ ] **Step 1: Add the hex initializer to `Colors.swift`**

Append to `DiskGallery/Support/Colors.swift` (after the existing extensions):

```swift
extension Color {
    /// Build a Color from a `0xRRGGBB` literal.
    init(hex: UInt32) {
        self.init(
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255
        )
    }
}
```

- [ ] **Step 2: Create `AccentPalette.swift`**

```swift
// DiskGallery/Support/AccentPalette.swift
import SwiftUI
import DiskGalleryCore

/// Resolved SwiftUI colors for an accent, derived from the design tokens in diskgallery.css.
struct AccentPalette {
    let accent: Color       // --accent (drives .tint)
    let accentDeep: Color   // --accent-deep (gradient stop / brand mark)
    let ink: Color          // --accent-ink (text/icon on an accent fill)
    /// --accent-glow: the accent at glow opacity, for colored shadows.
    var glow: Color { accent.opacity(0.45) }
    /// --accent-soft: the accent at fill opacity, for selection backgrounds.
    var soft: Color { accent.opacity(0.16) }
}

extension Accent {
    /// The resolved palette. Exhaustive — the compiler guarantees every accent is covered.
    var palette: AccentPalette {
        switch self {
        case .violet:   AccentPalette(accent: Color(hex: 0xA78BFF), accentDeep: Color(hex: 0x6F4CE0), ink: Color(hex: 0x15101F))
        case .blue:     AccentPalette(accent: Color(hex: 0x5AA2FF), accentDeep: Color(hex: 0x2F6AD6), ink: Color(hex: 0x04101F))
        case .green:    AccentPalette(accent: Color(hex: 0x54E0A0), accentDeep: Color(hex: 0x1EA372), ink: Color(hex: 0x04130C))
        case .amber:    AccentPalette(accent: Color(hex: 0xF7C14E), accentDeep: Color(hex: 0xCF851E), ink: Color(hex: 0x1C1304))
        case .coral:    AccentPalette(accent: Color(hex: 0xFF855F), accentDeep: Color(hex: 0xD6492A), ink: Color(hex: 0x1D0C05))
        case .graphite: AccentPalette(accent: Color(hex: 0x7D90B5), accentDeep: Color(hex: 0x5C739E), ink: Color(hex: 0x0C1018))
        }
    }
}

/// Fixed (non-accent) OLED screen tokens, from diskgallery.css.
enum OLEDColor {
    static let screenTop = Color(hex: 0x090B0F)
    static let screen    = Color(hex: 0x040506)
    static let ink       = Color(hex: 0xF3F1E9)
    static let ink2      = Color(hex: 0xF3F1E9).opacity(0.62)
    static let ink3      = Color(hex: 0xF3F1E9).opacity(0.40)
    static let ok        = Color(hex: 0x4ADE80)
    static let warn      = Color(hex: 0xF7B955)
    static let bad       = Color(hex: 0xF8736B)
}
```

- [ ] **Step 3: Regenerate + build to verify it compiles**

Run: `xcodegen generate && xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -25`
Expected: `** BUILD SUCCEEDED **` (the app still uses `AppTheme` at this point — untouched — so it links fine).

- [ ] **Step 4: Commit**

```bash
git add DiskGallery/Support/Colors.swift DiskGallery/Support/AccentPalette.swift DiskGallery.xcodeproj
git commit -m "Add Color(hex:), AccentPalette, and fixed OLED screen tokens"
```

---

## Task 4: `OLEDDisplayView` (+ previews) and a public `VolumeSummary` init

The OLED component renders three layouts. It depends only on `VolumeSummary`, `Format`, `Capacity`, `OLEDLayout`, and `AccentPalette` — not on `ThemeStore` — so it compiles before the model swap. A public memberwise initializer is added to `VolumeSummary` so previews (and future tests) can construct one.

**Files:**
- Modify: `DiskGalleryCore/Library/LibraryService.swift` (add `public init` to `VolumeSummary`, after line 17 inside the struct)
- Create: `DiskGallery/Views/OLEDDisplayView.swift`

- [ ] **Step 1: Add a public initializer to `VolumeSummary`**

Insert inside `struct VolumeSummary { … }` in `DiskGalleryCore/Library/LibraryService.swift`, immediately after the stored properties (after `public var latestSnapshotComplete: Bool?`):

```swift
    public init(id: Int64, uuid: String?, name: String, latestSnapshotId: Int64?,
                scannedAt: Date?, totalCapacity: Int64?, freeCapacity: Int64?,
                fsType: String?, fileCount: Int64?, totalLogical: Int64?,
                rootEntryId: Int64?, latestSnapshotComplete: Bool?) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.latestSnapshotId = latestSnapshotId
        self.scannedAt = scannedAt
        self.totalCapacity = totalCapacity
        self.freeCapacity = freeCapacity
        self.fsType = fsType
        self.fileCount = fileCount
        self.totalLogical = totalLogical
        self.rootEntryId = rootEntryId
        self.latestSnapshotComplete = latestSnapshotComplete
    }
```

(Adding an explicit initializer does not affect `Codable`/`FetchableRecord`, which use the synthesized `Decodable` init.)

- [ ] **Step 2: Create `OLEDDisplayView.swift`**

```swift
// DiskGallery/Views/OLEDDisplayView.swift
import SwiftUI
import DiskGalleryCore

/// CrateDigger-style OLED telemetry panel for the selected drive — the Modern skin's hero.
/// Always renders dark (it's a screen) regardless of the app's appearance mode.
struct OLEDDisplayView: View {
    let summary: VolumeSummary
    let connected: Bool
    var browsePath: String? = nil
    let layout: OLEDLayout
    let palette: AccentPalette

    private var fraction: Double { Capacity.fractionUsed(total: summary.totalCapacity, free: summary.freeCapacity) }
    private var over: Bool { Capacity.isOverCapacity(total: summary.totalCapacity, free: summary.freeCapacity) }
    private var percent: Int { Int((fraction * 100).rounded()) }
    private var usedBytes: Int64? {
        guard let total = summary.totalCapacity else { return nil }
        return max(0, total - (summary.freeCapacity ?? 0))
    }

    var body: some View {
        content
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
            .background(screen)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(scanlines)
            .overlay(vignette)
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.black, lineWidth: 1))
            .shadow(color: palette.glow, radius: 26)
            .shadow(color: .black.opacity(0.55), radius: 28, y: 16)
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        switch layout {
        case .telemetry: telemetry
        case .gauge:     gauge
        case .minimal:   minimal
        }
    }

    // MARK: Chassis

    private var screen: some View {
        LinearGradient(colors: [OLEDColor.screenTop, OLEDColor.screen], startPoint: .top, endPoint: .bottom)
            .overlay(RadialGradient(colors: [palette.accent.opacity(0.09), .clear],
                                    center: .topLeading, startRadius: 0, endRadius: 360))
    }

    private var scanlines: some View {
        Canvas { ctx, size in
            let shading = GraphicsContext.Shading.color(.white.opacity(0.022))
            var y: CGFloat = 0
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: shading)
                y += 3
            }
        }
        .blendMode(.screen)
        .allowsHitTesting(false)
    }

    private var vignette: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(RadialGradient(colors: [.clear, .black.opacity(0.5)], center: .center, startRadius: 70, endRadius: 340))
            .blendMode(.multiply)
            .allowsHitTesting(false)
    }

    // MARK: Layout A — Telemetry

    private var telemetry: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                OLEDTag(text: "Selected Drive", palette: palette)
                Text(summary.name.uppercased())
                    .font(.system(size: 12, weight: .semibold, design: .monospaced)).tracking(1)
                    .foregroundStyle(OLEDColor.ink).lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    OLEDPill(text: connected ? "Connected" : "Disconnected", live: connected)
                    if let fs = summary.fsType, !fs.isEmpty { OLEDPill(text: fs.uppercased()) }
                    if summary.scannedAt != nil { OLEDPill(text: "Scanned \(Format.relativeDate(summary.scannedAt))") }
                }
            }
            HStack(alignment: .top, spacing: 0) {
                OLEDStatCell(k: "Capacity", value: Format.bytes(summary.totalCapacity),
                             sub: summary.freeCapacity.map { "\(Format.bytes($0)) free" })
                cellDivider
                OLEDStatCell(k: "Used", value: Format.bytes(usedBytes),
                             sub: summary.totalCapacity == nil ? nil : "\(percent)% full",
                             tint: palette.accent, glow: palette.glow)
                cellDivider
                OLEDStatCell(k: "Files", value: Format.count(summary.fileCount), sub: "cataloged")
            }
            OLEDBottomBar(uuid: summary.uuid, fraction: fraction, over: over, path: browsePath, palette: palette)
        }
    }

    private var cellDivider: some View {
        Rectangle().fill(OLEDColor.ink.opacity(0.10)).frame(width: 1, height: 44).padding(.horizontal, 18)
    }

    // MARK: Layout B — Gauge

    private var gauge: some View {
        HStack(spacing: 28) {
            ZStack {
                Circle().stroke(OLEDColor.ink.opacity(0.10), lineWidth: 13)
                Circle().trim(from: 0, to: fraction)
                    .stroke(over ? OLEDColor.bad : palette.accent, style: StrokeStyle(lineWidth: 13, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: palette.glow, radius: 10)
                VStack(spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(percent)").font(.system(size: 38, weight: .bold, design: .monospaced)).foregroundStyle(OLEDColor.ink)
                        Text("%").font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundStyle(OLEDColor.ink2)
                    }
                    OLEDKey("Used")
                }
            }
            .frame(width: 150, height: 150)

            VStack(alignment: .leading, spacing: 10) {
                OLEDTag(text: "Selected Drive", palette: palette)
                Text(summary.name).font(.system(size: 24, weight: .bold)).foregroundStyle(OLEDColor.ink).lineLimit(1)
                Text(gaugeSubtitle).font(.system(size: 11, design: .monospaced)).foregroundStyle(OLEDColor.ink2)
                HStack(spacing: 24) {
                    OLEDStatCell(k: "Capacity", value: Format.bytes(summary.totalCapacity))
                    OLEDStatCell(k: "Used", value: Format.bytes(usedBytes), tint: palette.accent, glow: palette.glow)
                    OLEDStatCell(k: "Files", value: Format.count(summary.fileCount))
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var gaugeSubtitle: String {
        var parts: [String] = []
        if let free = summary.freeCapacity { parts.append("\(Format.bytes(free)) free") }
        if let fs = summary.fsType, !fs.isEmpty { parts.append(fs) }
        parts.append(connected ? "connected" : "disconnected")
        return parts.joined(separator: " · ")
    }

    // MARK: Layout C — Minimal

    private var minimal: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                OLEDTag(text: "Selected Drive", palette: palette)
                Spacer()
                OLEDPill(text: connected ? "Connected" : "Disconnected", live: connected)
            }
            Text(summary.name).font(.system(size: 40, weight: .heavy)).foregroundStyle(OLEDColor.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
            OLEDCapacityBar(fraction: fraction, over: over, palette: palette).frame(height: 11)
            HStack(spacing: 30) {
                OLEDInline(value: Format.bytes(usedBytes), unit: "used")
                if let free = summary.freeCapacity { OLEDInline(value: Format.bytes(free), unit: "free") }
                OLEDInline(value: Format.count(summary.fileCount), unit: "files")
            }
        }
    }
}

// MARK: - Shared OLED subviews

private struct OLEDTag: View {
    let text: String
    let palette: AccentPalette
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(palette.ink).frame(width: 6, height: 6)
            Text(text.uppercased()).font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.4)
        }
        .foregroundStyle(palette.ink)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(palette.accent, in: Capsule())
    }
}

private struct OLEDPill: View {
    let text: String
    var live: Bool = false
    var body: some View {
        HStack(spacing: 6) {
            if live { Circle().fill(OLEDColor.ok).frame(width: 6, height: 6).shadow(color: OLEDColor.ok, radius: 4) }
            Text(text.uppercased()).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.2)
        }
        .foregroundStyle(live ? OLEDColor.ok : OLEDColor.ink2)
        .padding(.horizontal, 10).padding(.vertical, 3)
        .overlay(Capsule().strokeBorder(live ? OLEDColor.ok.opacity(0.55) : OLEDColor.ink3, lineWidth: 1))
    }
}

private struct OLEDKey: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 8.5, weight: .semibold, design: .monospaced))
            .tracking(1.8).foregroundStyle(OLEDColor.ink3).lineLimit(1)
    }
}

private struct OLEDStatCell: View {
    let k: String
    let value: String
    var sub: String? = nil
    var tint: Color = OLEDColor.ink
    var glow: Color? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            OLEDKey(k)
            Text(value).font(.system(size: 26, weight: .bold, design: .monospaced)).foregroundStyle(tint)
                .shadow(color: glow ?? .clear, radius: glow == nil ? 0 : 14).lineLimit(1)
            if let sub { OLEDKey(sub) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OLEDInline: View {
    let value: String
    let unit: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value).font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundStyle(OLEDColor.ink)
            Text(unit.uppercased()).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(OLEDColor.ink2)
        }
    }
}

private struct OLEDCapacityBar: View {
    let fraction: Double
    let over: Bool
    let palette: AccentPalette
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(OLEDColor.ink.opacity(0.08))
                Capsule()
                    .fill(over ? AnyShapeStyle(OLEDColor.bad)
                               : AnyShapeStyle(LinearGradient(colors: [palette.accentDeep, palette.accent],
                                                              startPoint: .leading, endPoint: .trailing)))
                    .frame(width: max(0, geo.size.width * fraction))
                    .shadow(color: over ? OLEDColor.bad.opacity(0.6) : palette.glow, radius: 8)
            }
        }
    }
}

private struct OLEDBottomBar: View {
    let uuid: String?
    let fraction: Double
    let over: Bool
    let path: String?
    let palette: AccentPalette
    var body: some View {
        HStack(spacing: 14) {
            if let uuid, !uuid.isEmpty { OLEDKey("VOL \(uuid.prefix(8))") }
            OLEDCapacityBar(fraction: fraction, over: over, palette: palette).frame(height: 9)
            if let path, !path.isEmpty {
                Text(path).font(.system(size: 10, design: .monospaced)).foregroundStyle(OLEDColor.ink2)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 260, alignment: .trailing)
            }
        }
        .padding(.top, 4)
    }
}

#if DEBUG
private extension VolumeSummary {
    static var preview: VolumeSummary {
        VolumeSummary(id: 1, uuid: "8F2AC71D-AB12", name: "Archive Vault",
                      latestSnapshotId: 1, scannedAt: Date(timeIntervalSinceNow: -172_800),
                      totalCapacity: 4_000_000_000_000, freeCapacity: 842_000_000_000,
                      fsType: "APFS", fileCount: 248_193, totalLogical: 3_160_000_000_000,
                      rootEntryId: 1, latestSnapshotComplete: true)
    }
}

#Preview("Telemetry · Violet") {
    OLEDDisplayView(summary: .preview, connected: true, browsePath: "/Volumes/Archive Vault/Photography",
                    layout: .telemetry, palette: Accent.violet.palette)
        .padding(24).frame(width: 860).background(.black)
}
#Preview("Gauge · Blue") {
    OLEDDisplayView(summary: .preview, connected: true, layout: .gauge, palette: Accent.blue.palette)
        .padding(24).frame(width: 860).background(.black)
}
#Preview("Minimal · Green") {
    OLEDDisplayView(summary: .preview, connected: false, layout: .minimal, palette: Accent.green.palette)
        .padding(24).frame(width: 860).background(.black)
}
#endif
```

- [ ] **Step 3: Regenerate + build to verify it compiles**

Run: `xcodegen generate && xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -25`
Expected: `** BUILD SUCCEEDED **`. (Optional: open `OLEDDisplayView.swift` in Xcode and confirm the three `#Preview`s render — recessed dark panel, scanlines, accent glow, capacity bar.)

- [ ] **Step 4: Commit**

```bash
git add DiskGalleryCore/Library/LibraryService.swift DiskGallery/Views/OLEDDisplayView.swift DiskGallery.xcodeproj
git commit -m "Add OLEDDisplayView (telemetry/gauge/minimal) + VolumeSummary public init"
```

---

## Task 5: Switch the app to the new theme model + expose all controls

Rewrite `ThemeStore` to the four-axis model with migration, update the two `.tint` call sites, and rebuild `AppearanceSettings` with Look / Mode / Accent / OLED Display sections. These three files must land together so the app compiles (removing `AppTheme` breaks the old call sites).

**Files:**
- Modify: `DiskGallery/App/ThemeStore.swift` (full rewrite)
- Modify: `DiskGallery/App/DiskGalleryApp.swift:104` (tint)
- Modify: `DiskGallery/Views/SettingsView.swift` (`AppearanceSettings` struct, lines 68-104)

- [ ] **Step 1: Rewrite `ThemeStore.swift`**

Replace the entire contents of `DiskGallery/App/ThemeStore.swift` with:

```swift
import SwiftUI
import Observation
import DiskGalleryCore

/// System / light / dark. (Skin, Accent, and OLEDLayout live in DiskGalleryCore.)
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

@MainActor
@Observable
final class ThemeStore {
    private let defaults = UserDefaults.standard

    var skin: Skin              { didSet { defaults.set(skin.rawValue, forKey: "skin") } }
    var accent: Accent          { didSet { defaults.set(accent.rawValue, forKey: "accent") } }
    var mode: AppearanceMode    { didSet { defaults.set(mode.rawValue, forKey: "appearanceMode") } }
    var oledLayout: OLEDLayout  { didSet { defaults.set(oledLayout.rawValue, forKey: "oledLayout") } }

    init() {
        skin = Skin(rawValue: defaults.string(forKey: "skin") ?? "") ?? .modern
        mode = AppearanceMode(rawValue: defaults.string(forKey: "appearanceMode") ?? "") ?? .system
        oledLayout = OLEDLayout(rawValue: defaults.string(forKey: "oledLayout") ?? "") ?? .telemetry
        // Accent: prefer the new key; otherwise migrate the legacy `theme` value once.
        if let raw = defaults.string(forKey: "accent"), let stored = Accent(rawValue: raw) {
            accent = stored
        } else {
            let migrated = ThemeMigration.accent(fromLegacy: defaults.string(forKey: "theme"))
            accent = migrated
            defaults.set(migrated.rawValue, forKey: "accent")
        }
    }
}
```

- [ ] **Step 2: Update the tint in `DiskGalleryApp.swift`**

In `DiskGallery/App/DiskGalleryApp.swift`, change line 104:

```swift
        .tint(env.theme.theme.accent)
```
to:
```swift
        .tint(env.theme.accent.palette.accent)
```
(Leave both `.preferredColorScheme(env.theme.mode.colorScheme)` calls unchanged.)

- [ ] **Step 3: Rebuild `AppearanceSettings` in `SettingsView.swift`**

Replace the entire `struct AppearanceSettings: View { … }` (lines 68-104) with:

```swift
struct AppearanceSettings: View {
    @Environment(AppEnvironment.self) private var env

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 12)]

    var body: some View {
        @Bindable var theme = env.theme
        Form {
            Section("Look") {
                Picker("Skin", selection: $theme.skin) {
                    ForEach(Skin.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Section("Mode") {
                Picker("Appearance", selection: $theme.mode) {
                    ForEach(AppearanceMode.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Section("Accent") {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Accent.allCases) { option in
                        Button { env.theme.accent = option } label: {
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(option.palette.accent)
                                    .frame(width: 36, height: 36)
                                    .overlay(Circle().strokeBorder(env.theme.accent == option ? Color.primary : .clear, lineWidth: 2.5))
                                Text(option.name).font(.caption)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                Picker("Layout", selection: $theme.oledLayout) {
                    ForEach(OLEDLayout.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(theme.skin == .classic)
            } header: {
                Text("OLED Display")
            } footer: {
                Text("The OLED drive display appears in the Modern look.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .tint(env.theme.accent.palette.accent)
    }
}
```

- [ ] **Step 4: Regenerate + build to verify the whole app compiles**

Run: `xcodegen generate && xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -25`
Expected: `** BUILD SUCCEEDED **` with no remaining references to `AppTheme` or `theme.theme`.

- [ ] **Step 5: Commit**

```bash
git add DiskGallery/App/ThemeStore.swift DiskGallery/App/DiskGalleryApp.swift DiskGallery/Views/SettingsView.swift DiskGallery.xcodeproj
git commit -m "Switch to four-axis theme model (skin/accent/mode/OLED) + Settings controls"
```

---

## Task 6: Show the OLED hero in the Modern skin

Branch `VolumeBrowserView` on the active skin: Modern shows `OLEDDisplayView` + a compact action row (keeping Changes…/Re-scan); Classic keeps today's `DriveHeaderBar`.

**Files:**
- Modify: `DiskGallery/Views/VolumeBrowserView.swift` (the `VolumeBrowserView.body`, lines 11-43, and add a `ModernActionRow`)

- [ ] **Step 1: Replace the header block in `VolumeBrowserView.body`**

In `DiskGallery/Views/VolumeBrowserView.swift`, replace this block at the top of the `VStack` (lines 13-16):

```swift
            if summary.latestSnapshotId != nil {
                DriveHeaderBar(summary: summary) { showChanges = true }
                Divider()
            }
```
with:
```swift
            if summary.latestSnapshotId != nil {
                if env.theme.skin == .modern {
                    OLEDDisplayView(
                        summary: summary,
                        connected: env.volumes.isConnected(key: summary.uuid ?? summary.name),
                        browsePath: "/Volumes/\(summary.name)",
                        layout: env.theme.oledLayout,
                        palette: env.theme.accent.palette
                    )
                    .padding(12)
                    ModernActionRow(summary: summary) { showChanges = true }
                    Divider()
                } else {
                    DriveHeaderBar(summary: summary) { showChanges = true }
                    Divider()
                }
            }
```

- [ ] **Step 2: Add `ModernActionRow` below `DriveHeaderBar`**

Insert after the closing brace of `struct DriveHeaderBar` (around line 89):

```swift
/// Compact action row shown under the OLED hero in the Modern skin — keeps the
/// Changes… / Re-scan actions that DriveHeaderBar provides in Classic.
struct ModernActionRow: View {
    @Environment(AppEnvironment.self) private var env
    let summary: VolumeSummary
    let onShowChanges: () -> Void

    var body: some View {
        let connected = env.volumes.isConnected(key: summary.uuid ?? summary.name)
        HStack(spacing: 8) {
            Spacer()
            Button(action: onShowChanges) {
                Label("Changes…", systemImage: "clock.arrow.2.circlepath")
            }
            .help("Compare this drive’s scans to see what changed")
            if connected {
                Button { env.rescan(volume: summary) } label: {
                    Label("Re-scan", systemImage: "arrow.clockwise")
                }
                .help("Scan again to update the catalog and detect changes")
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -25`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add DiskGallery/Views/VolumeBrowserView.swift
git commit -m "Show OLED hero (Modern skin) atop the volume browser; keep Classic header"
```

---

## Task 7: README, full build/test, and manual verification

**Files:**
- Modify: `README.md:30`

- [ ] **Step 1: Update the Themes bullet in `README.md`**

Replace line 30:

```markdown
- **Themes** — six accent themes with light / dark / system mode, in Settings.
```
with:
```markdown
- **Themes** — a **Classic** or **Modern** look (the Modern look adds a CrateDigger-style
  **OLED drive display** with Telemetry / Gauge / Minimal layouts), six accent colors, and
  light / dark / system mode — all in Settings.
```

- [ ] **Step 2: Run the full Core test suite**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **` (all existing tests + `ThemeModelTests` + `CapacityTests`).

- [ ] **Step 3: Full app build**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -25`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Manual verification (run the app)**

Launch the built app (or run from Xcode). Confirm:
- A previously-scanned drive shows the **OLED hero** at the top of the browser (Modern is the default skin).
- **Settings → Appearance**: switching **Look** to Classic restores the old `DriveHeaderBar` and dims the OLED Display picker; back to Modern restores the OLED hero.
- Changing **Accent** updates the tint everywhere (selection, capacity bars, brand) and the OLED accent/glow.
- **OLED Display** picker switches Telemetry / Gauge / Minimal live.
- **Mode** System/Light/Dark behaves; the OLED panel stays dark in Light mode (it's a screen).
- Existing users keep their accent: a prior `theme=grape` shows as **Violet** selected (migration).

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "Document Classic/Modern themes + OLED display in README"
```

---

## Self-Review

**Spec coverage:**
- §1 Theme model (4 axes, defaults, migration) → Tasks 1, 5. ✓
- §2 Accent palette (tokens, `.tint`) → Task 3, Task 5 (tint call sites). ✓
- §3 OLED display (3 layouts, chassis, capacity bar, data fallback to Capacity/Used/Files) → Task 4. ✓
- §4 Placement (Modern hero vs Classic header) → Task 6. ✓
- §5 Settings UI (Look / Mode / Accent / OLED Display) → Task 5. ✓
- §6 Persistence/migration/tests → Tasks 1 (migration + raw-value stability), 2 (capacity), 4 (previews). ✓

**Type consistency (checked across tasks):**
- `Skin`, `Accent`, `OLEDLayout`, `ThemeMigration.accent(fromLegacy:)` defined in Task 1; used identically in Tasks 3, 4, 5, 6.
- `AccentPalette` fields `accent` / `accentDeep` / `ink` / `glow` / `soft` defined in Task 3; `OLEDDisplayView` and Settings use exactly these.
- `Capacity.fractionUsed` / `isOverCapacity` defined in Task 2; used in Task 4.
- `ThemeStore` properties `skin` / `accent` / `mode` / `oledLayout` defined in Task 5; bound in Settings (Task 5) and read in Task 6.
- `VolumeSummary.init(...)` (Task 4) matches the struct's stored-property order in `LibraryService.swift`.

**Placeholder scan:** No TBD/TODO; every code step contains complete, compilable code; every command has expected output. ✓

**Defaults note:** Telemetry ships lean (Capacity / Used / Files) per the approved spec; Folders and per-drive Duplicated cells are intentionally omitted (no backing field) and can be added later behind small Core count queries.
