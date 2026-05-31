# Modern Bento Faithful Redo — Implementation Plan

> **For agentic workers:** Implement task-by-task. Steps use checkbox (`- [ ]`) syntax. The exhaustive token/value tables live in the spec `docs/superpowers/specs/2026-05-31-modern-bento-faithful-redo-design.md` — read it alongside this plan; this plan gives structure + the non-obvious code.

**Goal:** Rebuild the Modern skin as a pixel-faithful two-pane bento workspace matching the Claude Design handoff bundle, across all Modern screens, full-bleed — without touching the Classic skin or Core logic.

**Architecture:** Branch the app root on `skin`. Modern uses a 2-column `NavigationSplitView` (glass sidebar + one workspace pane). The workspace stacks topbar → OLED hero (volume only) → bento. Reusable Modern primitives (GlassCard, topbar buttons, chips, tiles, inspector) are composed per route. Classic keeps the existing 3-column split verbatim.

**Tech Stack:** SwiftUI (macOS 15+, Swift 6), `DiskGalleryCore` framework, XcodeGen (`project.yml` → regenerate with `/opt/homebrew/bin/xcodegen generate`).

**Per-task gate (replaces TDD):**
- After file creation: `/opt/homebrew/bin/xcodegen generate`
- Build: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build` → `** BUILD SUCCEEDED **`
- Regression: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS,arch=arm64' test` stays green (run at start + end; no Core changes expected).
- **Classic invariant:** every Modern branch gated on `modern` (`env.theme.skin == .modern`); Classic code path unchanged.
- Commit after each task.

**Convention:** `private var modern: Bool { env.theme.skin == .modern }` in every view that branches.

---

### Task 0: Baseline

- [ ] **Step 1:** Confirm branch + clean tree.
Run: `git branch --show-current` (expect `modern-bento-exact`), `git status --short` (expect clean).
- [ ] **Step 2:** Baseline Core tests.
Run the DiskGalleryCore test command above. Expected: all pass (48).
- [ ] **Step 3:** Baseline app build (current code).
Run the build command. Expected: `** BUILD SUCCEEDED **`.

---

### Task 1: Token foundation (`Support/`)

**Files:**
- Modify: `DiskGallery/Support/AccentPalette.swift`
- Modify: `DiskGallery/Support/Colors.swift`
- Create: `DiskGallery/Support/ModernTokens.swift`

- [ ] **Step 1:** Verify `AccentPalette` exposes (or computes) for each accent: `accent`, `accent2`, `accentDeep`, `accentInk`, plus derived `glow` (= `accent.opacity(0.45)` for violet/blue/coral, `0.42` for green/amber) and `soft` (= `accent.opacity(0.16)`). If the struct only has `accent/accentDeep/ink`, add `accent2` and the derived accessors using the exact hex from spec §3.4. Keep `graphite` as the existing neutral.
- [ ] **Step 2:** Confirm `Color(hex: UInt32)` exists in `Colors.swift` (it does). Add `Color(hex:opacity:)` if not present.
- [ ] **Step 3:** Create `ModernTokens.swift` — a `ModernInk`/`ModernSurface` enum or static `Color` set for the non-accent tokens, resolving by `colorScheme`:

```swift
import SwiftUI

/// Mockup tokens that don't depend on the accent. Values from spec §3.1/§3.2.
enum DGToken {
    // ink
    static func ink(_ s: ColorScheme) -> Color   { s == .dark ? Color(hex: 0xEDEFF4) : Color(hex: 0x1A1D26) }
    static func ink2(_ s: ColorScheme) -> Color  { s == .dark ? Color(hex: 0xA6ABB7) : Color(hex: 0x535A68) }
    static func ink3(_ s: ColorScheme) -> Color  { s == .dark ? Color(hex: 0x6C7280) : Color(hex: 0x838A98) }
    static func ink4(_ s: ColorScheme) -> Color  { s == .dark ? Color(hex: 0x474D5B) : Color(hex: 0xAAB0BC) }
    // glass / hairlines
    static func hair(_ s: ColorScheme) -> Color  { s == .dark ? Color.white.opacity(0.085) : Color(hex: 0x0F1423).opacity(0.10) }
    static func hair2(_ s: ColorScheme) -> Color { s == .dark ? Color.white.opacity(0.16)  : Color(hex: 0x0F1423).opacity(0.16) }
    static func glass2(_ s: ColorScheme) -> Color{ s == .dark ? Color.white.opacity(0.072) : Color.white.opacity(0.82) }
    static func inset(_ s: ColorScheme) -> Color { s == .dark ? Color.black.opacity(0.45)  : Color(hex: 0x0F1423).opacity(0.08) }
    static let bg0 = Color(hex: 0x08090C)
    static let bg2 = Color(hex: 0x11141A)
    // status (fixed)
    static let ok = Color(hex: 0x4ADE80), warn = Color(hex: 0xF7B955), bad = Color(hex: 0xF8736B)
}

/// Finder colors (fixed, both modes) — spec §3.3.
extension FinderColor {
    var modernColor: Color {
        switch self {
        case .red: Color(hex: 0xF8736B); case .orange: Color(hex: 0xF6A23C)
        case .yellow: Color(hex: 0xF5CF52); case .green: Color(hex: 0x5FD38A)
        case .blue: Color(hex: 0x5AA2FF); case .purple: Color(hex: 0xB78CFF)
        case .gray: Color(hex: 0x8A909D); case .none: Color.clear
        }
    }
}

/// Tag → mockup signal color (spec §10).
extension Tag {
    var modernColor: Color {
        switch self {
        case .keep: DGToken.ok; case .delete: DGToken.bad; case .review: DGToken.warn
        case .move: Color(hex: 0xB78CFF); case .backup: Color(hex: 0x5AA2FF); case .none: DGToken.ink3(.dark)
        }
    }
}
```
(Adjust `FinderColor`/`Tag` case spellings to the real enums; `import DiskGalleryCore`.)
- [ ] **Step 4:** `xcodegen generate`; build; commit `"Modern tokens: exact color set from mockup (spec §3)"`.

---

### Task 2: Glass primitives (`Views/Modern/ModernGlass.swift`)

**Files:** Modify `DiskGallery/Views/Modern/ModernGlass.swift`

- [ ] **Step 1:** Keep `GlassCard` (radius 20, `.regularMaterial`, hairline `DGToken.hair`, shadow `0 18px 44px -22px black@0.8`). Confirm it matches spec §3.5.
- [ ] **Step 2:** Add a card header view:

```swift
struct ModernCardHeader: View {
    @Environment(\.colorScheme) private var scheme
    let systemImage: String
    let title: String
    let meta: String
    var accent: Color
    var body: some View {
        HStack(alignment: .center) {
            HStack(spacing: 9) {
                Image(systemName: systemImage).font(.system(size: 16)).foregroundStyle(accent)
                Text(title).font(.system(size: 13, weight: .bold))
            }
            Spacer(minLength: 8)
            Text(meta).font(.system(size: 9.5, design: .monospaced))
                .tracking(0.8).foregroundStyle(DGToken.ink3(scheme))
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 26))
    }
}
```
- [ ] **Step 3:** Add `ChipView` (tag chip, spec §9) and `ColorDot` (10px finder dot with glass ring):

```swift
struct ChipView: View {
    let tag: Tag
    var body: some View {
        Text(tag.label.uppercased())
            .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.0)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tag.modernColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .foregroundStyle(tag.modernColor)
    }
}
struct ColorDot: View {
    let color: FinderColor
    var body: some View {
        Circle().fill(color.modernColor).frame(width: 10, height: 10)
            .overlay(Circle().strokeBorder(.regularMaterial, lineWidth: 2))
    }
}
```
- [ ] **Step 4:** Add a mono uppercase label modifier `.modernMonoLabel(size:tracking:)` (used by section headers/lbls) and keep `.modernListChrome(_:)`.
- [ ] **Step 5:** `xcodegen generate`; build; commit `"Modern glass primitives: card header, chip, color dot, mono label"`.

---

### Task 3: Full-bleed window (`Views/Modern/WindowAccessor.swift`)

**Files:** Create `DiskGallery/Views/Modern/WindowAccessor.swift`

- [ ] **Step 1:** Implement the accessor (spec §4.2):

```swift
import SwiftUI
import AppKit

/// Toggles full-bleed (hidden title bar) on the hosting NSWindow.
struct WindowChrome: NSViewRepresentable {
    var fullBleed: Bool
    func makeNSView(context: Context) -> NSView { let v = NSView(); DispatchQueue.main.async { apply(to: v.window) }; return v }
    func updateNSView(_ nsView: NSView, context: Context) { DispatchQueue.main.async { apply(to: nsView.window) } }
    private func apply(to window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = fullBleed
        window.titleVisibility = fullBleed ? .hidden : .visible
        window.isMovableByWindowBackground = fullBleed
        if fullBleed { window.styleMask.insert(.fullSizeContentView) }
        else { window.styleMask.remove(.fullSizeContentView) }
    }
}
extension View {
    func modernWindowChrome(_ fullBleed: Bool) -> some View { background(WindowChrome(fullBleed: fullBleed)) }
}
```
- [ ] **Step 2:** `xcodegen generate`; build; commit `"Full-bleed window chrome accessor (Modern)"`.

---

### Task 4: Root shell branch (`App/DiskGalleryApp.swift`)

**Files:** Modify `DiskGallery/App/DiskGalleryApp.swift` (`ContentView`)

- [ ] **Step 1:** Split `ContentView.body` on `modern`. Keep the existing 3-column `NavigationSplitView` verbatim in a `classicSplit` computed property. Add:

```swift
var body: some View {
    Group {
        if modern { modernSplit } else { classicSplit }
    }
    .background { if modern { SpatialBackdrop(palette: env.theme.accent.palette) } }
    .modernWindowChrome(modern)
    .sheet(/* existing ScanProgressView */) ...
    .alert(/* existing */) ...
    .tint(env.theme.accent.palette.accent)
    .preferredColorScheme(env.theme.mode.colorScheme)
}

private var modernSplit: some View {
    NavigationSplitView {
        ModernSidebar().navigationSplitViewColumnWidth(min: 248, ideal: 272)
    } detail: {
        ModernWorkspace()
    }
}
```
(`classicSplit` = today's `NavigationSplitView { LibrarySidebarView() } content: { ContentColumn() } detail: { EntryDetailView() }` exactly.)
- [ ] **Step 2:** Create stub `ModernSidebar` (wrap existing `LibrarySidebarView` for now) and `ModernWorkspace` (route to existing `ContentColumn` for now) so the project compiles. These get filled in Tasks 5/11/12.
- [ ] **Step 3:** `xcodegen generate`; build; **manually toggle skin** mentally — Classic path is the untouched `classicSplit`. Commit `"Root: branch shell on skin (Modern = two-pane)"`.

---

### Task 5: Modern sidebar (`Views/Modern/ModernSidebar.swift`)

**Files:** Create `DiskGallery/Views/Modern/ModernSidebar.swift`. Read `LibrarySidebarView.swift` for the data sources (volume summaries, tag counts, reclaimable total, selection binding).

- [ ] **Step 1:** Build the container: `GlassCard`-style glass (radius 20), `VStack(spacing:0)` of `brand`, `scanButton`, `ScrollView { nav }`. Top padding +28 for traffic-light clearance (spec §4.2/§6).
- [ ] **Step 2:** `brand` — 36×36 squircle gradient mark (`LinearGradient(150°, accent → accentDeep)`), `externaldrive.fill` glyph in `accentInk`; "DiskGallery" 16/700; "OFFLINE CATALOG" mono 8.5 tracking 0.22em ink-3. Exact per spec §6.
- [ ] **Step 3:** `scanButton` — height 38, radius 12, `LinearGradient(180°, accent → accent2)`, label "SCAN A DRIVE" mono 10.5 tracking 0.18em 700 `accentInk` + plus icon; `.buttonStyle(.plain)`; action = existing scan entry point from `LibrarySidebarView`.
- [ ] **Step 4:** Nav sections (Library / Plan / Action Tags / Drives N/M) with `ModernNavSectionHeader` (mono 8.5 tracking 0.22em ink-4) + `ModernNavItem`:

```swift
struct ModernNavItem: View {
    @Environment(\.colorScheme) private var scheme
    let systemImage: String; let title: String; var badge: String? = nil
    let selected: Bool; var accent: Color; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: systemImage).font(.system(size: 16)).frame(width: 18)
                    .foregroundStyle(selected ? accent : DGToken.ink3(scheme))
                Text(title).font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(selected ? DGToken.ink(scheme) : DGToken.ink2(scheme))
                Spacer(minLength: 6)
                if let badge, !badge.isEmpty {
                    Text(badge).font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(selected ? accent.opacity(0.18) : DGToken.glass2(scheme), in: Capsule())
                        .foregroundStyle(selected ? accent : DGToken.ink3(scheme))
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(selected ? accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? accent.opacity(0.40) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
```
Tag icons: keep=`checkmark.circle`, delete=`trash`, review=`questionmark.circle`, move=`arrow.right.circle`, backup=`shippingbox` (or `externaldrive.badge.plus`). Action Tags order: Keep, Delete, Review, Move, Backup.
- [ ] **Step 5:** `ModernDriveRow` — status dot (8px; connected `DGToken.ok` + glow shadow, else ink-4) + name (13/600 truncating) + optional incomplete glyph (warn); sub mono 9 ink-3 (`"<size> · <files> files"` or warn "Incomplete — resume to finish"); 4px minibar (inset track, fill accent, or `bad` if fraction ≥ 0.92). Selected drive → glass2 + inset hair2 border. Tap → `env.selection = .volume(id)`.
- [ ] **Step 6:** `xcodegen generate`; build; commit `"Modern sidebar: glass brand/scan/nav/drives (spec §6)"`.

---

### Task 6: Modern topbar (`Views/Modern/ModernTopbar.swift`)

**Files:** Create `DiskGallery/Views/Modern/ModernTopbar.swift`

- [ ] **Step 1:** `ModernTopbar` with parameters: `crumbs: [String]` (or a `title`), `showVolumeActions: Bool`, callbacks. Layout: `HStack(spacing:14)` → breadcrumbs, `Spacer`, search pill, (volume) tbtn cluster. Height ~36, `padding(.horizontal,2).padding(.top,2)`.
- [ ] **Step 2:** Breadcrumbs — leading `externaldrive` icon (ink-3) + segments joined by `/` (sep ink-4, non-cur ink-3, cur ink/600). For volume route, build from `nav` path; ancestor tap navigates up.
- [ ] **Step 3:** Search pill — width 260, height 36, `Capsule`, glass + hair border, magnifier + "Search all drives" (13) + `⌘K` kbd (mono 10 on glass2, radius 6). Tap → `env.selection = .search`. Add a `.keyboardShortcut("k", modifiers: .command)` hidden button or wire via commands.
- [ ] **Step 4:** `TBtn` button style + the three buttons (spec §7):

```swift
struct TBtnStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(DGToken.ink2(scheme))
            .frame(height: 36).padding(.horizontal, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(DGToken.hair(scheme), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
```
  - **Display**: refresh-arrow icon + "Display" + mode chip (`Text(env.theme.oledLayout.name.uppercased())` mono 10 tracking 0.12em 700 accent on `accent.opacity(0.16)`, radius 7). Action `env.theme.cycleOLEDLayout()`.
  - **Check changes**: `clock.arrow.2.circlepath` + label → present `ChangesView` via a `@Binding showChanges`.
  - **Re-scan**: `arrow.clockwise` + label → `env.rescan(volume:)`; only when connected.
- [ ] **Step 5:** `xcodegen generate`; build; commit `"Modern topbar: breadcrumbs, search pill, Display/Check/Re-scan (spec §7)"`.

---

### Task 7: OLED verify/align (`Views/OLEDDisplayView.swift`)

**Files:** Modify `DiskGallery/Views/OLEDDisplayView.swift`

- [ ] **Step 1:** Compare each layout against spec §8 exact values: chassis height 216, telemetry cells grid `1.3fr + 4×1fr` with dividers, value 30px, gauge ring r72 stroke13 (dashoffset from %), pct 38px, minimal name 40px/800. Fix any deltas.
- [ ] **Step 2:** Confirm crossfade-in-place between layouts (active/entering/leaving transforms ~0.45s) and the one-shot flash + sweep on switch. Add if missing (a `@State` trigger keyed on `oledLayout` driving `withAnimation`).
- [ ] **Step 3:** `xcodegen generate` (if needed); build; commit `"OLED: align to exact mockup values + crossfade FX (spec §8)"`.

---

### Task 8: Browser card (`Views/Modern/ModernBrowser.swift`)

**Files:** Create `DiskGallery/Views/Modern/ModernBrowser.swift`. Read `VolumeBrowserView.swift` `FolderView` for data (children, annotations, selection, nav.open, tag menu).

- [ ] **Step 1:** `ModernFrow` row content:

```swift
struct ModernFrow: View {
    @Environment(\.colorScheme) private var scheme
    let entry: Entry; let annotation: Annotation?; var accent: Color
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDir ? "folder.fill" : "doc")
                .font(.system(size: 18)).frame(width: 20)
                .foregroundStyle(entry.isDir ? accent : DGToken.ink3(scheme))
            fname.frame(maxWidth: .infinity, alignment: .leading).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 7) {
                if let t = annotation?.tag, t != .none { ChipView(tag: t) }
                if let c = annotation?.color, c != .none { ColorDot(color: c) }
            }
            Text(Format.bytes(entry.displaySize))
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(DGToken.ink2(scheme))
                .frame(minWidth: 66, alignment: .trailing)
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
    }
    private var fname: some View { /* name in 13.5/500; ext suffix in ink3 */ }
}
```
- [ ] **Step 2:** `ModernFolderView` — keep SwiftUI `List(selection:)` for native multi-select/keyboard/context-menu/`primaryAction` (double-click open), but: `.listStyle(.plain)`, `.scrollContentBackground(.hidden)`, row = `ModernFrow`, `.listRowBackground` paints selection (`accent.opacity(0.16)` + inset `accent.opacity(0.42)` border on a `RoundedRectangle(cornerRadius:11)`), `.listRowSeparator(.hidden)`, `.listRowInsets` ~ `EdgeInsets(top:1,leading:12,bottom:1,trailing:18)`. Preserve the existing context-menu/tag/primaryAction logic verbatim.
- [ ] **Step 3:** Wrap in a `GlassCard` with `ModernCardHeader(systemImage:"folder.fill", title: folder.name, meta: "<n> items · <size>", accent:)`.
- [ ] **Step 4:** `xcodegen generate`; build; commit `"Modern browser: frow rows + glass card (spec §9)"`.

---

### Task 9: Inspector content (`Views/EntryDetailView.swift`)

**Files:** Modify `DiskGallery/Views/EntryDetailView.swift`

- [ ] **Step 1:** Extract the Modern inspector inner content into `ModernInspectorContent` (no outer scroll/card — the bento card provides those): insp-hero (52 squircle accent gradient + title 16/700 + kind mono 9.5 uppercase), spec grid `84/1fr` mono (Size in accent), section headers, tagbtns, swatches, finder note. Match spec §10 exactly.
- [ ] **Step 2:** Tag buttons — fixed 3-column `Grid`/`LazyVGrid`, **order Keep, Delete, Review, Move, Backup, None** (do NOT use `Tag.actionTags` order). Active = `tag.modernColor` text + 1px border + `tag.modernColor.opacity(0.14)` fill; icon-over-mono-label.
- [ ] **Step 3:** Swatches — `FinderColor.keyOrder` as 24px circles + a leading `none` (glass2 + slash). **Active ring = `DGToken.ink(scheme)` 2px, offset 2** (NOT accent — spec §10).
- [ ] **Step 4:** Provide `ModernInspectorCard` = `GlassCard { ModernCardHeader("info.circle","Inspector", meta:"N selected"); ScrollView { ModernInspectorContent } }`. Keep `EntryInspector`/`MultiSelectInspector` Classic `Form` paths intact for the Classic detail column.
- [ ] **Step 5:** `xcodegen generate`; build; commit `"Modern inspector content card (spec §10)"`.

---

### Task 10: Stat tiles (`Views/Modern/StatTiles.swift`)

**Files:** Modify `DiskGallery/Views/Modern/StatTiles.swift`

- [ ] **Step 1:** `ReclaimableTile` — `GlassCard` with `tile-reclaim` gradient overlay (`accent.opacity(0.12)` over glass); lbl "Reclaimable · Duplicates"; big-num 48/800 accent + unit 21/700 ink-2 (split `Format.bytes` value/unit); stack-bar 8px three segments (accent/blue/ink-4; proportions from duplicate breakdown if available else 46/30/24); bottom row "N sets across M drives" + "View →". Tap → `.duplicates`.
- [ ] **Step 2:** `ActionPlanTile` — lbl "Action Plan · N tagged"; plan-rows grid `70/1fr/auto` for Keep, Backup, Review, Delete (mockup's four): label (8px square pdot tag color + 12/600) + 7px track (inset bg, fill `tag.modernColor`, width = share of max) + amt (mono 11, value, min 52, right); bottom row "N drives to connect" + "Open plan →". Tap → `.plan`.
- [ ] **Step 3:** `xcodegen generate`; build; commit `"Modern stat tiles: reclaimable + action plan (spec §11)"`.

---

### Task 11: Volume bento workspace (`Views/Modern/ModernWorkspace.swift`)

**Files:** Create/expand `DiskGallery/Views/Modern/ModernWorkspace.swift`. Read `VolumeBrowserView.swift` + `BrowserNav`.

- [ ] **Step 1:** `VolumeBentoWorkspace(summary:)`:

```swift
VStack(spacing: 14) {
    ModernTopbar(crumbs: nav.crumbs, showVolumeActions: true, onChanges: { showChanges = true }, summary: summary)
    if summary.latestSnapshotId != nil {
        OLEDDisplayView(summary: summary, connected: ..., browsePath: ..., layout: env.theme.oledLayout, palette: env.theme.accent.palette)
            .frame(height: 216)
    }
    bento   // see step 2
}
.padding(14)
.sheet(isPresented: $showChanges) { ChangesView(summary: summary) }
```
- [ ] **Step 2:** `bento` — exact fractions (spec §5):

```swift
HStack(spacing: 14) {
    VStack(spacing: 14) {
        ModernBrowserCard(...)                       // 1.12 weight
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1.12)
        HStack(spacing: 14) { ReclaimableTile(...); ActionPlanTile(...) }  // 0.88 weight
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(0.88)
    }
    .frame(maxWidth: .infinity)
    ModernInspectorCard().frame(maxWidth: .infinity, maxHeight: .infinity)  // spans both rows
}
```
Use a `GeometryReader` to enforce the **1.55 : 1** left:right width ratio (left `width * 1.55/2.55`). Rows ratio 1.12:0.88 via two equal-priority frames sized by a height GeometryReader, or nested `GeometryReader`.
- [ ] **Step 3:** Replace the stub `ModernWorkspace` router to dispatch `.volume` → `VolumeBentoWorkspace`. (Other routes still fall through to a temporary `ContentColumn` wrap — fixed in Task 12.)
- [ ] **Step 4:** `xcodegen generate`; build; **visual check** vs `02-oled-settled.png` (telemetry/gauge/minimal via Display button). Commit `"Volume bento workspace: topbar + OLED + bento grid (spec §5/§C)"`.

---

### Task 12: Other-route shell + router (`Views/Modern/ModernWorkspace.swift`)

**Files:** Modify `ModernWorkspace.swift`; lightly modify route views (`DuplicatesView`, `SearchResultsView`, `ActionPlanView`, `TransferPlannerView`, `TaggedListView`) to expose Modern card-friendly content.

- [ ] **Step 1:** `RouteBentoWorkspace(title:systemImage:searchFocused:content:)` = `VStack(spacing:14){ ModernTopbar(title:, showVolumeActions:false); bento }` where bento = `HStack(spacing:14){ GlassCard{ ModernCardHeader + content } (1.55) ; ModernInspectorCard() (1) }`, `.padding(14)`.
- [ ] **Step 2:** Router cases: `.duplicates/.search/.plan/.transfer/.tagged(tag)` → `RouteBentoWorkspace` wrapping the existing route view body with `.scrollContentBackground(.hidden)` and `.modernListChrome(true)`. Reuse existing view internals; only the chrome changes. Provide the right title + icon per route.
- [ ] **Step 3:** `nil` selection → `ContentUnavailableView` (Modern-styled).
- [ ] **Step 4:** `xcodegen generate`; build; visual check each route. Commit `"Modern route bento shell for all non-volume screens (spec §12)"`.

---

### Task 13: Wiring & polish

**Files:** as needed (`ModernTopbar`, `ModernSidebar`, `DiskGalleryApp`).

- [ ] **Step 1:** Breadcrumb ancestor navigation (pop `nav.path` to the tapped segment).
- [ ] **Step 2:** ⌘K → `.search` (app command or hidden shortcut button). Confirm Display/Check/Re-scan all fire.
- [ ] **Step 3:** Traffic-light clearance: verify the +28 top inset on the sidebar; nudge if buttons overlap the brand.
- [ ] **Step 4:** Light mode + every accent quick pass (toggle in Settings). Confirm OLED stays dark in light mode.
- [ ] **Step 5:** `xcodegen generate`; build; commit `"Modern wiring + polish: crumbs nav, ⌘K, light mode, accents"`.

---

### Task 14: Verification & Classic-invariant audit

- [ ] **Step 1:** Core tests green (run the test command). App build green.
- [ ] **Step 2:** **Classic-unchanged audit** — `git diff main -- DiskGallery` and confirm: (a) no Classic code path altered (every Modern addition is gated), (b) `ContentView.classicSplit` is byte-identical to the old `body`, (c) `EntryInspector`/`MultiSelectInspector` Classic `Form` intact. Toggle skin → Classic looks/behaves as before.
- [ ] **Step 3:** Adversarial fidelity review — go component by component against spec §6–§11 and the bundle screenshots (`01-states.png`, `02-oled-settled.png`, `preview.png`, `v2-default.png`): sidebar, topbar (Display chip), OLED ×3, browser rows/chips, inspector (tag grid order, ink swatch ring), tiles (48px num, stacked bar, plan rows). List deltas, fix, rebuild.
- [ ] **Step 4:** Final commit `"Modern bento faithful redo complete (spec coverage verified)"`. Offer the user a visual smoke check before finishing the branch.

---

## Self-review — spec coverage map

| Spec § | Task |
|---|---|
| §3 tokens / accents / finder / tag colors | 1 |
| §4.1 root branch | 4 |
| §4.2 full-bleed window | 3, 13 |
| §4.3 router | 4, 11, 12 |
| §5 bento metrics | 11 |
| §6 sidebar | 5 |
| §7 topbar | 6 |
| §8 OLED | 7 |
| §9 browser | 8 |
| §10 inspector | 9 |
| §11 stat tiles | 10 |
| §12 other routes | 12 |
| §13 wiring | 6, 11, 12, 13 |
| §2 Classic invariant | every task + 14 |
| §15 verification | 0, 14 |

No placeholders; types consistent (`DGToken`, `ModernCardHeader`, `ChipView`, `ColorDot`, `ModernInspectorContent`, `ModernInspectorCard`, `TBtnStyle`, `VolumeBentoWorkspace`, `RouteBentoWorkspace` defined before use). Tag display order pinned in Tasks 5 & 9.
