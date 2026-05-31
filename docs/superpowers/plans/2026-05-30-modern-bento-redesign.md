# Modern Bento Redesign Implementation Plan

> **For agentic workers:** This plan is executed by a **Workflow** (multi-agent orchestration) — one implementer per task in dependency order, each followed by spec + quality review. Steps use checkbox (`- [ ]`) syntax. Tasks 1–2 are the shared foundation and MUST land first; Tasks 3–9 depend on them and each touch a distinct view file.

**Goal:** Extend the Modern skin across the whole interface — a spatial backdrop, frosted-glass surfaces, accent styling, and stat tiles — over the existing 3-column `NavigationSplitView`, leaving Classic byte-for-byte unchanged.

**Architecture:** A small shared styling layer (`SpatialBackdrop`, `GlassCard`/`.glassCard()`, `.modernListChrome()`, stat tiles) in `DiskGallery/Views/Modern/`, applied in place via modifiers that **no-op in Classic**. Each view gets a `private var modern: Bool { env.theme.skin == .modern }` gate; structural Modern branches appear only where the design genuinely differs, and the `else` branch is the original code verbatim.

**Tech Stack:** Swift 6, SwiftUI, macOS 15+, XcodeGen (`xcodegen generate` after adding files), `xcodebuild`.

**Spec:** `docs/superpowers/specs/2026-05-30-modern-bento-redesign-design.md`

**Conventions (every task):**
- After creating NEW files, run `xcodegen generate` and `git add DiskGallery.xcodeproj`.
- Build: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -25` → `** BUILD SUCCEEDED **`.
- **Classic invariant:** every Modern change is gated on `modern`; the Classic path must be the original code. Don't alter Classic rendering.
- These are styling tasks — no data/navigation/selection changes.

**Existing API available:** `env.theme.skin` (`Skin`), `env.theme.accent.palette` (`AccentPalette` → `.accent/.accentDeep/.glow/.soft/.ink`), `Color(hex:)`, `OLEDColor`, `env.totalReclaimable: Int64`, `env.tagCounts: [Tag: Int]`, `env.selection` (`SidebarItem`: `.duplicates`, `.plan`, …), `Tag.actionTags`, `Tag.label`, `Tag.swiftUIColor`, `Format.bytes(_:)`.

---

## Task 1: Foundation — spatial backdrop + glass surfaces + list chrome

**Files:**
- Create: `DiskGallery/Views/Modern/ModernBackdrop.swift`
- Create: `DiskGallery/Views/Modern/ModernGlass.swift`
- Modify: `DiskGallery/App/DiskGalleryApp.swift` (wrap `ContentView` body in the backdrop when Modern)

- [ ] **Step 1: Create `ModernBackdrop.swift`**

```swift
import SwiftUI

/// The Modern skin's full-bleed spatial canvas: a near-black (dark) / soft (light)
/// gradient base with accent radial glows. Sits behind the whole window in Modern.
struct SpatialBackdrop: View {
    let palette: AccentPalette
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            LinearGradient(
                colors: dark
                    ? [Color(hex: 0x08090C), Color(hex: 0x0C0E13), Color(hex: 0x11141A)]
                    : [Color(hex: 0xE9EAEF), Color(hex: 0xEEF0F4), Color(hex: 0xF4F6F9)],
                startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [palette.accent.opacity(dark ? 0.22 : 0.11), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 620)
            RadialGradient(colors: [palette.accent.opacity(dark ? 0.12 : 0.06), .clear],
                           center: UnitPoint(x: 1.02, y: 0.14), startRadius: 0, endRadius: 720)
            RadialGradient(colors: [Color(hex: 0x5078FF).opacity(dark ? 0.10 : 0.05), .clear],
                           center: UnitPoint(x: 0.6, y: 1.16), startRadius: 0, endRadius: 600)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
```

- [ ] **Step 2: Create `ModernGlass.swift`**

```swift
import SwiftUI

/// The design's frosted-glass `.card` surface.
struct GlassCard<Content: View>: View {
    var radius: CGFloat = 20
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(scheme == .dark ? Color.white.opacity(0.085) : Color.black.opacity(0.10),
                                  lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.12), radius: 22, y: 14)
    }
}

extension View {
    /// Wrap any view in the Modern glass-card surface.
    func glassCard(radius: CGFloat = 20) -> some View { GlassCard(radius: radius) { self } }

    /// In Modern, let the backdrop show through a List/Form. No-op in Classic.
    @ViewBuilder
    func modernListChrome(_ modern: Bool) -> some View {
        if modern { self.scrollContentBackground(.hidden) } else { self }
    }
}
```

- [ ] **Step 3: Wrap `ContentView` in the backdrop (Modern only)** — in `DiskGallery/App/DiskGalleryApp.swift`, the `ContentView.body` currently is `NavigationSplitView { … } content: { … } detail: { … }` followed by `.sheet/.alert/.tint/.preferredColorScheme`. Add a `private var modern` and a background. Change the `body` to:

```swift
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
        .background(modern ? SpatialBackdrop(palette: env.theme.accent.palette) : nil)
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
        .preferredColorScheme(env.theme.mode.colorScheme)
    }

    private var modern: Bool { env.theme.skin == .modern }
```

`.background(_:)` accepts an optional `View?`; passing `nil` in Classic adds nothing. (If the compiler rejects the ternary-to-nil, use `.background { if modern { SpatialBackdrop(palette: env.theme.accent.palette) } }`.)

- [ ] **Step 4: Regenerate, build**

`xcodegen generate && xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -25` → `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add DiskGallery/Views/Modern/ModernBackdrop.swift DiskGallery/Views/Modern/ModernGlass.swift DiskGallery/App/DiskGalleryApp.swift DiskGallery.xcodeproj
git commit -m "Add Modern spatial backdrop + glass surfaces + list-chrome modifier"
```

**Acceptance:** builds; in Modern a spatial backdrop sits behind the window; `GlassCard`/`.glassCard()`/`.modernListChrome()` available; Classic shows no backdrop.

---

## Task 2: Stat tiles (`ReclaimableTile`, `ActionPlanTile`)

**Files:**
- Create: `DiskGallery/Views/Modern/StatTiles.swift`

- [ ] **Step 1: Create `StatTiles.swift`**

```swift
import SwiftUI
import DiskGalleryCore

/// Modern dashboard tiles for the volume-browser workspace. Read existing env data only.

struct ReclaimableTile: View {
    @Environment(AppEnvironment.self) private var env
    let palette: AccentPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reclaimable · Duplicates").modernTileLabel()
            Text(Format.bytes(env.totalReclaimable))
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundStyle(palette.accent)
                .lineLimit(1).minimumScaleFactor(0.6)
            Spacer(minLength: 0)
            Button { env.selection = .duplicates } label: { Text("View →").modernTileLabel() }
                .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .glassCard()
    }
}

struct ActionPlanTile: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Action Plan").modernTileLabel()
            VStack(spacing: 8) {
                ForEach([Tag.keep, .backup, .review, .delete]) { tag in
                    HStack(spacing: 8) {
                        Text(tag.label).font(.caption).foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.quaternary)
                                Capsule().fill(tag.swiftUIColor)
                                    .frame(width: geo.size.width * share(tag))
                            }
                        }
                        .frame(height: 6)
                        Text("\(env.tagCounts[tag] ?? 0)")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
            Spacer(minLength: 0)
            Button { env.selection = .plan } label: { Text("Open plan →").modernTileLabel() }
                .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .glassCard()
    }

    /// Bar width as a share of the largest action-tag count (0 when nothing tagged).
    private func share(_ tag: Tag) -> Double {
        let maxCount = Tag.actionTags.map { env.tagCounts[$0] ?? 0 }.max() ?? 0
        guard maxCount > 0 else { return 0 }
        return Double(env.tagCounts[tag] ?? 0) / Double(maxCount)
    }
}

private extension View {
    func modernTileLabel() -> some View {
        self.font(.system(size: 10, weight: .semibold, design: .monospaced))
            .textCase(.uppercase).tracking(1).foregroundStyle(.secondary)
    }
}

#if DEBUG
#Preview("Stat tiles") {
    HStack { ReclaimableTile(palette: Accent.violet.palette); ActionPlanTile() }
        .frame(width: 520, height: 200).padding(40)
        .background(SpatialBackdrop(palette: Accent.violet.palette))
        .environment(try! AppEnvironment())
}
#endif
```

- [ ] **Step 2: Regenerate, build** (same build command). If the `#Preview`'s `try! AppEnvironment()` fails to compile or is undesirable in the app target, drop the `#Preview` block — the tiles are exercised live in Task 4.

- [ ] **Step 3: Commit**

```bash
git add DiskGallery/Views/Modern/StatTiles.swift DiskGallery.xcodeproj
git commit -m "Add Modern Reclaimable + Action Plan stat tiles"
```

**Acceptance:** builds; both tiles render as glass cards reading `env.totalReclaimable` / `env.tagCounts`; their buttons set `env.selection`.

---

## Task 3: Sidebar Modern styling (`LibrarySidebarView`)

**Files:**
- Modify: `DiskGallery/Views/LibrarySidebarView.swift`

- [ ] **Step 1: Add the `modern` gate + list chrome.** Add `private var modern: Bool { env.theme.skin == .modern }`. On the top-level `List(selection:)`, append `.modernListChrome(modern)` so the spatial backdrop shows through in Modern. (Native selection is already accent-tinted via the root `.tint`.)

- [ ] **Step 2: Mono-caps section headers in Modern.** Wrap each `Section("…")`'s title so Modern uses a mono-caps header while Classic keeps the default. Replace each `Section("X") { … }` with `Section { … } header: { sectionHeader("X") }` and add:

```swift
    @ViewBuilder private func sectionHeader(_ title: String) -> some View {
        if modern {
            Text(title).font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.5).textCase(.uppercase).foregroundStyle(.tertiary)
        } else {
            Text(title)
        }
    }
```

Apply to all four sections ("Library", "Plan", "Action Tags", "Drives").

- [ ] **Step 3: Modern drive-row accent dot.** In `DriveRow`, give the connection indicator a glow in Modern. Add `@Environment(AppEnvironment.self) private var env` is already present; compute `let modern = env.theme.skin == .modern`, and change the `externaldrive.fill` foreground to add, when connected & modern, `.shadow(color: .green, radius: 4)`. Leave Classic exactly as is. (Keep the existing `CapacityBar`, which already tints to the accent.)

- [ ] **Step 4: Build** (app scheme) → `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add DiskGallery/Views/LibrarySidebarView.swift
git commit -m "Modern sidebar: glass list chrome, mono-caps headers, accent drive dot"
```

**Acceptance:** builds; in Modern the sidebar floats on the backdrop with mono-caps headers and accent selection; Classic sidebar unchanged. (Note: macOS may retain a faint sidebar material — acceptable near-miss per the spec.)

---

## Task 4: Volume-browser workspace (`VolumeBrowserView`, Modern)

**Files:**
- Modify: `DiskGallery/Views/VolumeBrowserView.swift`

- [ ] **Step 1: `modern` gate.** Add `private var modern: Bool { env.theme.skin == .modern }` to `VolumeBrowserView`.

- [ ] **Step 2: Glass browser card + stat tiles.** The Modern branch already shows the OLED hero + `ModernActionRow`. Wrap the browsing area (the `NavigationStack`/`FolderView` `Group`) so that, in Modern, the file list reads as a glass card and the stat tiles sit beneath it. Concretely, in the `body`'s `Group { … }` that renders the `NavigationStack`, append `.modernListChrome(modern)` to the inner `List` (in `FolderView`, see Step 3), and in `VolumeBrowserView.body`, when `modern` and a snapshot exists, place a stat-tiles row at the bottom:

```swift
            if modern, summary.latestSnapshotId != nil {
                HStack(spacing: 12) {
                    ReclaimableTile(palette: env.theme.accent.palette)
                    ActionPlanTile()
                }
                .frame(height: 132)
                .padding([.horizontal, .bottom], 12)
            }
```

Insert this **after** the `Group { … }` browser block and before the closing of the outer `VStack`. In Classic, nothing is added.

- [ ] **Step 3: Modern list chrome + row tweak in `FolderView`/`EntryRow`.** Add `private var modern: Bool { env.theme.skin == .modern }` to `FolderView`; append `.modernListChrome(modern)` to its `List(selection:)`. `EntryRow` already shows folder icon, name, Finder-color dot, `TagChip`, and a mono size — no structural change needed; it inherits the accent via `.tint`. (Optional: in Modern, give the folder icon `Color.accentColor` — it already uses `Color.accentColor` for dirs.)

- [ ] **Step 4: Build** → `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add DiskGallery/Views/VolumeBrowserView.swift
git commit -m "Modern browser workspace: glass list chrome + Reclaimable/Action-Plan tiles"
```

**Acceptance:** builds; Modern volume view = OLED hero + action row + (glass) file list + stat tiles row; Classic unchanged.

---

## Task 5: Inspector Modern styling (`EntryDetailView`)

**Files:**
- Modify: `DiskGallery/Views/EntryDetailView.swift`

- [ ] **Step 1: `modern` gate + list chrome.** Add `private var modern: Bool { env.theme.skin == .modern }` to `EntryInspector` and `MultiSelectInspector`. Append `.modernListChrome(modern)` to their `Form`s so the backdrop shows through; the `Form`'s grouped sections then read as translucent cards over the canvas.

- [ ] **Step 2: Accent the spec + tag controls in Modern.** The existing `TagControls` (the `DecisionButton` grid + `ColorSwatch` row) already mirrors the design's `.tagbtn`/`.sw`. Make the active states use the accent where the design does: in `DecisionButton`, when `active`, the design fills/borders with the tag's semantic color — keep that (it matches). No change required for parity; just ensure `.modernListChrome(modern)` is applied so they sit on glass. (Leave `DecisionButton`/`ColorSwatch` logic intact.)

- [ ] **Step 3: Build** → `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add DiskGallery/Views/EntryDetailView.swift
git commit -m "Modern inspector: glass form chrome over the spatial backdrop"
```

**Acceptance:** builds; Modern inspector renders as translucent grouped sections on the backdrop with the existing tag-button grid + Finder swatches; Classic Form unchanged.

---

## Task 6: Duplicates restyle (`DuplicatesView`)

**Files:**
- Modify: `DiskGallery/Views/DuplicatesView.swift`

- [ ] **Step 1.** Add `private var modern: Bool { env.theme.skin == .modern }`. Append `.modernListChrome(modern)` to both `List`s (the `setsList` sets list and the `membersPanel` members list).

- [ ] **Step 2.** In Modern, accent the "Reclaimable: …" header figure: it currently uses `.foregroundStyle(.orange)`; leave Classic orange, but in Modern use `env.theme.accent.palette.accent`:
`.foregroundStyle(modern ? env.theme.accent.palette.accent : .orange)`. (Leave the per-row reclaimable figures as semantic orange — they read as a "savings" signal.)

- [ ] **Step 3: Build** → `** BUILD SUCCEEDED **`. **Commit:**

```bash
git add DiskGallery/Views/DuplicatesView.swift
git commit -m "Modern Duplicates: glass list chrome + accent reclaimable header"
```

**Acceptance:** builds; Modern Duplicates lists float on the backdrop; Classic unchanged.

---

## Task 7: Action Plan restyle (`ActionPlanView`)

**Files:**
- Modify: `DiskGallery/Views/ActionPlanView.swift`

- [ ] **Step 1.** Add `private var modern: Bool { env.theme.skin == .modern }`. Append `.modernListChrome(modern)` to the plan `List`.

- [ ] **Step 2.** The `header` row of `StatPill`s already uses semantic tints and rounded backgrounds — these read well on the backdrop unchanged. No structural change needed. (`DrivePlanRow`'s order badge already uses `Color.accentColor` when connected — inherits the accent.)

- [ ] **Step 3: Build** → `** BUILD SUCCEEDED **`. **Commit:**

```bash
git add DiskGallery/Views/ActionPlanView.swift
git commit -m "Modern Action Plan: glass list chrome over the backdrop"
```

**Acceptance:** builds; Modern Action Plan list floats on the backdrop; Classic unchanged.

---

## Task 8: Transfer Planner restyle (`TransferPlannerView`)

**Files:**
- Modify: `DiskGallery/Views/TransferPlannerView.swift`

- [ ] **Step 1.** Add `private var modern: Bool { env.theme.skin == .modern }`. Append `.modernListChrome(modern)` to the `itemList`'s `List`.

- [ ] **Step 2.** Wrap the `resultCard` in the glass surface when Modern (it currently uses a semantic-tinted rounded background). Change its trailing `.background(verdictColor(fits).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))` so that in Modern it instead uses `.glassCard(radius: 14)` layered over a faint verdict tint:

```swift
        .background(verdictColor(fits).opacity(modern ? 0.12 : 0.08),
                    in: RoundedRectangle(cornerRadius: modern ? 14 : 10))
```

(Keep the verdict colors semantic — green/red/secondary. This keeps the "fits / won't fit" signal legible. A full `.glassCard()` is optional; the tinted card already reads well on the backdrop.)

- [ ] **Step 3: Build** → `** BUILD SUCCEEDED **`. **Commit:**

```bash
git add DiskGallery/Views/TransferPlannerView.swift
git commit -m "Modern Transfer Planner: glass list chrome + verdict card on backdrop"
```

**Acceptance:** builds; Modern Transfer Planner floats on the backdrop with its verdict card legible; Classic unchanged.

---

## Task 9: Search + Tagged restyle (`SearchResultsView`, `TaggedListView`)

**Files:**
- Modify: `DiskGallery/Views/SearchResultsView.swift`
- Modify: `DiskGallery/Views/TaggedListView.swift`

- [ ] **Step 1.** In each view, add `@Environment(AppEnvironment.self) private var env` if not present and `private var modern: Bool { env.theme.skin == .modern }`. Append `.modernListChrome(modern)` to the primary `List` in each so results float on the backdrop. Do not change their data flow or row content.

- [ ] **Step 2: Build** → `** BUILD SUCCEEDED **`. **Commit:**

```bash
git add DiskGallery/Views/SearchResultsView.swift DiskGallery/Views/TaggedListView.swift
git commit -m "Modern Search + Tagged: glass list chrome over the backdrop"
```

**Acceptance:** builds; both views' lists float on the backdrop in Modern; Classic unchanged.

---

## Task 10: README + full verification

**Files:**
- Modify: `README.md`

- [x] **Step 1.** Update the Themes bullet (currently mentions Classic/Modern + OLED) to note the Modern look now spans the whole interface. Replace it with:

```markdown
- **Themes** — a **Classic** or **Modern** look. Modern restyles the whole interface as a
  bento/glass workspace: a spatial backdrop with accent glows, frosted-glass sidebar,
  inspector, and cards, the CrateDigger-style **OLED drive display** (Telemetry / Gauge /
  Minimal), and Reclaimable / Action-Plan stat tiles. Plus six accent colors and
  light / dark / system mode — all in Settings.
```

- [x] **Step 2: Full Core test suite** (regression guard): `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test 2>&1 | tail -20` → `** TEST SUCCEEDED **` (~48 tests). If any fail, STOP and report.
  - **Result (2026-05-30):** Executed 48 tests, with 0 failures — `** TEST SUCCEEDED **`

- [x] **Step 3: Full app build** → `** BUILD SUCCEEDED **`.
  - **Result (2026-05-30):** `** BUILD SUCCEEDED **` (arm64, Debug, macOS)

- [x] **Step 4: Commit**

```bash
git add README.md
git commit -m "Document the full Modern bento interface in README"
```

**Acceptance:** README updated; 48 Core tests pass; app builds. (Manual GUI eyeball — switch skin/accent/mode, visit every route — is a human step after the workflow.)

---

## Self-Review

**Spec coverage:**
- §1 shared layer (backdrop/glass/list-chrome) → Task 1; stat tiles → Task 2. ✓
- §2 root backdrop wiring → Task 1 Step 3. ✓
- §3 sidebar → Task 3. ✓
- §4 browser workspace + tiles → Task 4. ✓
- §5 inspector → Task 5. ✓
- §6 other routes (Duplicates/ActionPlan/Transfer/Search/Tagged) → Tasks 6–9. ✓
- §7 Classic-untouched + verification → every task's Classic gate + Task 10. ✓
- Deviation: the spec's optional `ModernRows.swift` is folded into the views (YAGNI) — no separate file. Noted.

**Placeholder scan:** Foundation tasks have complete code. View tasks specify exact modifier placements + the gated code. The restyles are deliberately light (the look comes from the shared layer + backdrop), so "apply `.modernListChrome(modern)`" IS the complete change for the simple routes — not a placeholder. No TBD/TODO.

**Type consistency:** `modern` gate is `env.theme.skin == .modern` everywhere; `.modernListChrome(_ modern: Bool)`, `.glassCard(radius:)`, `SpatialBackdrop(palette:)`, `ReclaimableTile(palette:)`, `ActionPlanTile()` signatures match their definitions in Tasks 1–2; `env.totalReclaimable`/`env.tagCounts`/`env.selection` match `AppEnvironment`.

**Risk note:** the sidebar/list background suppression (`.scrollContentBackground(.hidden)`) and the macOS sidebar material are the finickiest bits (spec §2/§8); reviewers should confirm the backdrop shows through and flag if a route's list stays opaque.
