# Modern OLED Theme & Selectable Theming — Design

_Date: 2026-05-30 · Status: approved (pending spec review)_

## Background

DiskGallery is a native SwiftUI macOS app that catalogs external drives so they stay
browsable offline. A Claude Design handoff bundle (`DiskGallery.html` +
`diskgallery.css`) reimagines the app as a full-bleed, bento-grid, glassmorphic
workspace whose centerpiece is a CrateDigger-style **OLED telemetry display** for the
selected drive. The mockup already builds in selectable **dark/light**, **5 accent
colors**, and **3 OLED layouts**.

The app already has theming scaffolding: `ThemeStore` exposes an `AppTheme` accent
(graphite/ocean/sunset/forest/grape/rose) and an `AppearanceMode`
(system/light/dark), applied at the root via `.tint(...)` and
`.preferredColorScheme(...)`. The UI is fully native (the file "browser" is a
SwiftUI `List` in a `NavigationSplitView` — there is no web view).

## Goals

1. Let the user pick **OLED display** layout, **accent color**, and **dark mode**.
2. Preserve today's exact look as a selectable **"Classic"** theme.
3. Ship the new look as a **"Modern"** theme: the OLED telemetry hero + the design's
   accent/dark styling, layered onto the **current 3-column layout** (no full bento
   rewrite).

## Non-goals (out of scope)

- A full native rebuild of the bento-grid workspace (sidebar/inspector/stat-tile
  layout). The current `NavigationSplitView` structure is kept.
- The mockup's **glass-blur slider** (dropped — YAGNI).
- Bundling Hanken Grotesk / JetBrains Mono. We use **system fonts**: SF Pro for UI,
  **SF Mono** for OLED/data readouts.
- Making the mockup's static controls interactive beyond what the app already does.

## Decisions (settled)

- **Scope**: OLED hero + theming on the current layout; Classic preserved. _(chosen)_
- **Accents**: unify on the design's palette, shared by both skins. _(chosen)_
- **Fonts**: system fonts (SF Pro + SF Mono). _(chosen)_
- **Default skin**: `modern` (ships the redesign front-and-center). _(approved)_
- **Default accent**: `violet` (the design's default). _(approved)_
- **OLED appears in Modern only**; Classic = today's UI untouched. _(approved)_

---

## 1. Theme model — `ThemeStore`

Refactor the store into **four orthogonal, independently-persisted axes**. Each
persists to `UserDefaults` via the existing `didSet` pattern.

```swift
enum Skin: String, CaseIterable, Identifiable { case classic, modern }      // NEW
enum Accent: String, CaseIterable, Identifiable {                            // replaces AppTheme
    case graphite, violet, blue, green, amber, coral
}
enum AppearanceMode: String, CaseIterable, Identifiable { case system, light, dark } // unchanged
enum OLEDLayout: String, CaseIterable, Identifiable { case telemetry, gauge, minimal } // NEW
```

| Axis | Default | UserDefaults key |
|------|---------|------------------|
| `skin` | `.modern` | `skin` |
| `accent` | `.violet` | `accent` (was `theme`) |
| `mode` | `.system` | `appearanceMode` (unchanged) |
| `oledLayout` | `.telemetry` | `oledLayout` |

**Migration** — on init, read the legacy `theme` key and map to the new accent, then
persist under `accent`:

| legacy `theme` | new `accent` |
|----------------|--------------|
| graphite | graphite |
| ocean | blue |
| forest | green |
| sunset | amber |
| rose | coral |
| grape | violet |

If neither `accent` nor legacy `theme` is present, default to `.violet`.

## 2. Accent palette — `AccentPalette`

A value type holding the design's token set per accent. Sourced verbatim from
`diskgallery.css`; `graphite` derived from today's neutral accent.

```swift
struct AccentPalette {
    let accent: Color      // --accent  (drives .tint)
    let accentDeep: Color  // --accent-deep (gradient stop / brand mark)
    let glow: Color        // --accent-glow (colored shadow)
    let soft: Color        // --accent-soft (selection / fills)
    let ink: Color         // --accent-ink (text/icon on accent fill)
}
```

Token values (hex / rgba from the CSS):

| Accent | accent | accent-deep | glow | soft | ink |
|--------|--------|-------------|------|------|-----|
| violet | `#a78bff` | `#6f4ce0` | `rgba(167,139,255,.45)` | `rgba(167,139,255,.16)` | `#15101f` |
| blue | `#5aa2ff` | `#2f6ad6` | `rgba(90,162,255,.45)` | `rgba(90,162,255,.16)` | `#04101f` |
| green | `#54e0a0` | `#1ea372` | `rgba(84,224,160,.42)` | `rgba(84,224,160,.16)` | `#04130c` |
| amber | `#f7c14e` | `#cf851e` | `rgba(247,193,78,.42)` | `rgba(247,193,78,.16)` | `#1c1304` |
| coral | `#ff855f` | `#d6492a` | `rgba(255,133,95,.45)` | `rgba(255,133,95,.16)` | `#1d0c05` |
| graphite | `#7d90b5` (derived) | `#5c739e` | `rgba(124,144,181,.40)` | `rgba(124,144,181,.16)` | `#0c1018` |

`env.theme.accent.palette.accent` replaces `env.theme.theme.accent` at the two
`.tint(...)` call sites (`ContentView`, `AppearanceSettings`). Because controls
inherit `.tint`, the existing `CapacityBar` (uses `Color.accentColor`), selection
highlights, and buttons pick up the accent automatically in **both** skins — no
per-view change required for basic accenting.

**Fixed (non-accent) tokens** used by the OLED panel, defined once as constants:

- OLED screen: `oled #040506`, `oled-2 #090b0f`
- OLED ink tiers: `#f3f1e9`, `rgba(243,241,233,.62)`, `rgba(243,241,233,.40)`
- Status signals: `ok #4ade80`, `warn #f7b955`, `bad #f8736b`

## 3. OLED display — `OLEDDisplayView`

A native recreation of the mockup's recessed panel. Inputs:
`OLEDDisplayView(summary: VolumeSummary, connected: Bool, browsePath: String?, layout: OLEDLayout, palette: AccentPalette)`.

**Chassis (shared by all layouts):**
- Rounded rect (radius 20), fill = vertical gradient `oled-2 → oled` plus a faint
  top-left accent radial; black hairline border.
- Layered shadows: inner top highlight + inner dark inset, outer drop shadow, and an
  **accent-glow** outer shadow (`palette.glow`).
- **Scanlines** overlay: a `Canvas` drawing 1px horizontal lines every 3px at ~2%
  white, `.blendMode(.screen)`; plus a vignette (inner dark radial) overlay.
- Always dark, in both light and dark mode (it's a screen).
- Text: **SF Mono**; ink tiers as above; accent key-numbers get `palette.accent`
  with a soft glow (`.shadow(color: palette.glow, radius: …)`).

**Layouts (switched by `OLEDLayout`):**

- **Telemetry** — top status row (accent "SELECTED DRIVE" tag pill, drive name + size,
  Connected/`fsType`/"scanned Nd ago" pills) → a row of stat cells
  (Capacity, Used [accent], Files, Folders, Duplicated [ok-green]) separated by
  hairlines → bottom bar (VOL UUID · capacity bar · `browsePath`).
- **Gauge** — left: accent capacity **ring** (`Circle().trim(...)` rotated −90°, round
  cap, accent stroke + glow) with `%` + "Used" in the center; right: name/size/free +
  Files / Folders / Duplicated stats.
- **Minimal** — large drive name, full-width capacity bar, inline stat row
  (used / free / files / reclaimable).

**Capacity bar** (OLED variant): track `rgba(243,241,233,.08)`, fill = accent gradient
(`accentDeep → accent`) with glow; turns **`bad`-red at ≥95% / over-capacity**,
matching the existing `CapacityBar.overCapacity` semantics.

**Data binding & fallback.** Available on `VolumeSummary`: `name`, `uuid`,
`totalCapacity`, `freeCapacity` (→ used, % full), `fsType`, `fileCount`, `scannedAt`
(→ `Format.relativeDate`), `latestSnapshotComplete`; `connected` via
`env.volumes.isConnected`; path via the current browse location or `/Volumes/<name>`.

Two cells in the mockup have **no backing field today**:
- **Folders count** — not stored. **Default: omit the Folders cell.** Optional
  upgrade (plan may take it): add a cheap `COUNT(*) WHERE isDir` to
  `LibraryService`/`VolumeSummary` and show it.
- **Per-drive reclaimable** — `env.totalReclaimable` is global only; showing it in a
  per-drive panel would mislead. **Default: omit the Duplicated cell.** Optional
  upgrade: a per-drive reclaimable query, then show it.

So the Telemetry layout ships with **Capacity / Used / Files** by default, expanding
to the full five cells only if the optional queries are added. Cells/pills render only
when their data is present (graceful degradation; no "—" clutter in the OLED).

## 4. Placement — Classic vs Modern

In `VolumeBrowserView`, when a `.volume` is selected, branch on `env.theme.skin`:

- **Modern**: `OLEDDisplayView` as the hero at the top (in place of `DriveHeaderBar`).
  The Re-scan / Changes… actions move to a compact control row directly beneath the
  OLED panel. The `IncompleteBanner` and the file `List` follow, unchanged.
- **Classic**: exactly today — `DriveHeaderBar` + `Divider()` + the browser.

Non-volume routes (Duplicates, Search, Plan, Transfer, Tagged) are unchanged in both
skins. Sidebar, list, and inspector keep their structure; Modern only inherits the
unified accent (via `.tint`) and the dark default.

## 5. Settings UI — `AppearanceSettings`

Extend the existing Appearance tab (order top→bottom):

1. **Look** — segmented `Picker` over `Skin` (Classic / Modern).
2. **Mode** — segmented `AppearanceMode` picker (unchanged).
3. **Accent** — the existing swatch `LazyVGrid`, now iterating the 6 unified
   `Accent` cases (swatch fill = `palette.accent`).
4. **OLED Display** — segmented `Picker` over `OLEDLayout`
   (Telemetry / Gauge / Minimal); **disabled/dimmed when `skin == .classic`** with a
   caption noting it applies to the Modern look.

All bind to `@Bindable var theme = env.theme`.

## 6. Persistence, migration, testing

- **Persistence**: each axis `didSet`→ `UserDefaults`, mirroring today's pattern.
- **Migration**: the legacy-`theme`→`accent` map in §1, applied once at init.
- **Tests** — the testable logic (migration map, palette exhaustiveness, OLED numeric
  helpers) is currently in the `DiskGallery` app target, which has no unit-test target
  (only `DiskGalleryCoreTests` for Core + `DiskGalleryUITests`). **Decision for the
  plan**: either keep these helpers free of SwiftUI so they can move to a small new
  app unit-test target, or extract the pure bits (e.g. the migration map, %/threshold
  math) into `DiskGalleryCore` where the existing test target covers them. Then:
  - `ThemeStore`: defaults, round-trip persistence, and legacy-`theme` migration for
    all six legacy values.
  - `AccentPalette`: every `Accent` case yields a complete, non-nil token set
    (exhaustiveness — guards against a missing case).
  - OLED logic helpers: `% full`, over-capacity threshold, "scanned Nd ago"
    formatting, and the missing-folder-count / missing-reclaimable fallbacks.
  - Visual: `#Preview`s for the three OLED layouts × a couple of accents × light/dark
    for manual inspection.

## Risks / mitigations

- **OLED fidelity in SwiftUI** (scanlines, glow, ring). Mitigation: `Canvas` for
  scanlines; `.shadow` for glow; `Circle().trim` for the ring — all standard. Previews
  to tune.
- **Migration regressions** for existing users' stored accent. Mitigation: explicit
  map + unit tests.
- **Default flip to Modern** surprising current users. Acceptable pre-1.0; Classic is
  one click away in Settings.

## Affected files

- `DiskGallery/App/ThemeStore.swift` — new axes, palette, migration.
- `DiskGallery/Support/Colors.swift` (or a new `AccentPalette.swift`) — palette tokens.
- `DiskGallery/Views/VolumeBrowserView.swift` — skin branch + OLED hero placement.
- `DiskGallery/Views/OLEDDisplayView.swift` — **new** component (3 layouts).
- `DiskGallery/Views/SettingsView.swift` — Look + OLED Display sections.
- `DiskGallery/App/DiskGalleryApp.swift` — `.tint` call site update.
- (maybe) `DiskGalleryCore/Library/LibraryService.swift` — folder-count query, if chosen.
- Tests under the appropriate target.
