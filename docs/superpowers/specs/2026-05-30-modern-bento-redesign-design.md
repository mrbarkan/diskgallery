# Modern Bento Redesign — Design

_Date: 2026-05-30 · Status: approved (pending spec review)_

## Background

The [Modern OLED theme](2026-05-30-modern-oled-theme-design.md) shipped a Classic↔Modern
skin switch, a unified `AccentPalette`, dark mode, and the OLED telemetry hero in the
volume browser. This phase extends the **Modern** skin to the rest of the interface —
the full bento/glassmorphic look from the Claude Design handoff (`DiskGallery.html` /
`diskgallery.css`): a dark **spatial canvas** with accent glows, **frosted-glass**
surfaces, an accent-highlighted glass **sidebar**, a glass **inspector**, and the
design's **stat tiles** (Reclaimable, Action Plan).

The app is a native SwiftUI `NavigationSplitView` (sidebar / content / detail). All
content routes are standard `List`/`Form`/`VSplitView` views. The Modern skin is read
from `env.theme.skin`; `env.theme.accent.palette` exposes `accent/accentDeep/glow/soft/ink`;
`OLEDColor` holds fixed OLED tokens.

## Goals

1. Apply the design's bento/glass visual language across the **entire Modern interface**:
   spatial backdrop, glass sidebar, glass cards, accent styling, and the stat tiles.
2. Keep the **3-column `NavigationSplitView`** structure (proven navigation/selection/
   keyboard plumbing) — restyle each region, don't rebuild the layout.
3. Leave the **Classic** skin byte-for-byte unchanged.

## Non-goals (out of scope)

- Replacing `NavigationSplitView` with a single custom bento pane.
- Any data-flow / navigation / selection / scanning changes. This is surfaces only.
- Re-theming the modal sheets (`ScanProgressView`, `ChangesView`) beyond what they
  inherit; they keep their current presentation.
- The glass-blur intensity slider (already dropped in the prior phase).

## Decisions (settled in brainstorming)

- **Layout**: keep the 3-column split; restyle regions + add stat tiles. _(chosen)_
- **Backdrop**: spatial canvas — override default column/window backgrounds with the
  dark/soft backdrop + accent glows. _(chosen)_
- **Breadth**: every content route restyled in this pass. _(chosen)_
- **Approach**: a shared Modern styling layer applied **in place via modifiers that
  no-op in Classic**, with small Modern structural branches only where the design
  genuinely differs (sidebar rows, inspector, browser workspace). Not a parallel view
  tree. _(approved)_
- Stat tiles live on the **volume-browser** screen (not a separate dashboard). _(approved)_

---

## 1. Shared Modern styling layer — `DiskGallery/Views/Modern/`

New, reusable, all gated on the active skin. Token values are taken from `diskgallery.css`.

### 1.1 `SpatialBackdrop` (`ModernBackdrop.swift`)
A `View` painting the full-bleed canvas:
- **Base**: dark mode → vertical blend of `bg-0 #08090C → bg-1 #0C0E13 → bg-2 #11141A`;
  light mode → `#E9EAEF → #EEF0F4 → #F4F6F9`. (Switch on `@Environment(\.colorScheme)`.)
- **Accent glows**: two `RadialGradient`s using `palette.accent` — top-left (~22% opacity
  in dark, ~11% in light) and upper-right (~12%) — plus a faint cool glow bottom-center
  (`rgba(80,120,255,0.10)`), matching the CSS `body::before`. Light mode halves glow opacity.
- Inputs: `palette: AccentPalette`. Ignores hit-testing; `.accessibilityHidden(true)`.

### 1.2 `GlassCard` / `.glassCard()` (`ModernGlass.swift`)
The design's `.card` surface as a reusable container/modifier:
- Fill: `.regularMaterial` (cards) — adapts to light/dark natively; this is the native
  equivalent of the CSS translucent-white + backdrop-blur.
- **Hairline border**: `RoundedRectangle(cornerRadius: 20, style: .continuous)
  .strokeBorder(hairline, lineWidth: 1)` where `hairline` = `Color.white.opacity(0.085)`
  (dark) / `Color.black.opacity(0.10)` (light).
- Corner radius `20` (`--radius`); soft shadow `0 18px 44px -22px black@0.8` →
  `.shadow(color: .black.opacity(0.45), radius: 22, y: 14)`.
- A `radius` parameter (default 20) so smaller chips can use `--radius-s/xs`.

### 1.3 `.modernListChrome(_ skin:)` (`ModernGlass.swift`)
A `ViewModifier` for `List`/`Form` so the backdrop shows through and selection reads
as accent:
- Modern → `.scrollContentBackground(.hidden)` (+ transparent row backgrounds where a
  view sets explicit ones). Classic → no-op (returns content unchanged).
- Selection tint already flows from the root `.tint(palette.accent)`.

### 1.4 Restyled rows / chips (`ModernRows.swift`)
Small Modern-only building blocks shared by sidebar + browser: an accent **nav-item**
style (`.nav-item.on` = `palette.soft` fill + `palette.accent` inset border + accent
icon/text), an accent **badge pill**, and the design's `.chip` (tag) + `.cdot`
(Finder-color dot) used in browser rows. The existing `TagChip` and
`FinderColor.swiftUIColor` are reused for colors.

### 1.5 Stat tiles (`StatTiles.swift`)
- **`ReclaimableTile`**: a `GlassCard` with the `.lbl` "Reclaimable · Duplicates", a big
  accent number from `env.totalReclaimable` (the design's `.big-num`/`.tile-reclaim`
  accent gradient background), a thin stacked bar, and a "View →" affordance that sets
  `env.selection = .duplicates`.
- **`ActionPlanTile`**: a `GlassCard` with per-tag rows (Keep/Backup/Review/Delete) —
  label + track bar (width ∝ that tag's share) + count — from `env.tagCounts`, and an
  "Open plan →" affordance setting `env.selection = .plan`. Colors from `Tag.swiftUIColor`.
Both read existing `env` data only (no new queries).

## 2. Root wiring — `ContentView` (`DiskGalleryApp.swift`)

When `skin == .modern`, place `SpatialBackdrop(palette:)` behind the `NavigationSplitView`
(via a `ZStack` or `.background`). Keep `.tint`/`.preferredColorScheme` as-is. In Classic,
render exactly as today (no backdrop). **Risk/caveat**: macOS gives the sidebar column a
vibrancy material that `.scrollContentBackground(.hidden)` may not fully remove. Mitigation
order: (a) `.scrollContentBackground(.hidden)` on the sidebar `List`; (b) a translucent
glass fill behind the sidebar content; (c) if a faint system material remains, accept it
as a near-miss (it still reads as glass-on-canvas). No NSWindow hacks unless trivial.

## 3. Sidebar — `LibrarySidebarView` (Modern branch)

- `.modernListChrome()` so the backdrop shows through; `.listStyle(.sidebar)` retained.
- Section headers (`Library/Plan/Action Tags/Drives`) → mono-caps, `ink-3`.
- Nav rows use the accent **nav-item** style when selected (accent-soft fill, accent
  icon/label, accent badge pill); hover/idle use a subtle glass-2 fill.
- `DriveRow`: unchanged structurally; its `CapacityBar` already tints to the accent. In
  Modern, give the row a subtle glass background and the connection dot a glow when up.
- Classic sidebar: unchanged.

## 4. Volume-browser workspace — `VolumeBrowserView` (Modern)

Compose the bento (the OLED hero already exists here):
1. **OLED hero** (done) + the existing `ModernActionRow`.
2. **Browser list as a `GlassCard`** — wrap the `List`; rows (`EntryRow`) restyled to the
   design's `.frow`: folder icon in accent, name, tag **chip** + Finder-color **dot**,
   mono right-aligned size. `EntryRow` already has icon/name/color-dot/`TagChip`/mono
   size — Modern just adjusts spacing/cardness and applies `.modernListChrome()`.
3. **Stat tiles row**: `ReclaimableTile` + `ActionPlanTile` below the browser.
Layout stacks vertically in the content column (OLED ~fixed, browser flexes, tiles
~fixed). Classic browser: unchanged.

## 5. Inspector — `EntryDetailView` (Modern branch)

A glass inspector (the design's `.insp`):
- Header: accent thumbnail tile + title + mono "kind" line.
- **Spec list**: Size (accent) / On-disk / Modified / Path as a mono `dt/dd` grid.
- **Action Tag**: the existing `TagControls` decision grid restyled as the design's
  `.tagbtn` (icon-over-label, accent/semantic active border+fill).
- **Finder Color**: the existing swatch row restyled as `.sw` circles with an accent ring
  on the active one.
- The `FinderSyncNote` (kept). Note field kept (single-selection).
Wrap in a `GlassCard` over the backdrop via `.modernListChrome()`. The existing
`TagControls`/`DecisionButton`/`ColorSwatch` are reused with Modern styling; Classic Form
path unchanged. `MultiSelectInspector` gets the same glass treatment.

## 6. Other content routes (restyle surfaces only)

Each adopts the backdrop (global) + `.modernListChrome()` and wraps its primary panel(s)
in `GlassCard`; **no data/logic changes**:
- **`DuplicatesView`**: the `VSplitView`'s sets list and members panel each become glass
  cards; the "Reclaimable" header figure uses the accent.
- **`ActionPlanView`**: the `StatPill` header row → glass/accent pills; the plan `List`
  → transparent on backdrop; `DrivePlanRow` order badge uses the accent.
- **`TransferPlannerView`**: the pickers row + `resultCard` + item list become glass; the
  verdict colors (`green/red/secondary`) stay semantic.
- **`SearchResultsView`**, **`TaggedListView`**: `.modernListChrome()` + a glass results
  card; rows reuse the browser row treatment where they show entries.

## 7. Classic untouched & testing

- All Modern styling is conditional/no-op in Classic. Where a view needs a structural
  Modern branch (sidebar selection style, inspector, browser workspace), the `else`
  branch is the original code verbatim. A self-check confirms Classic is visually identical.
- **Verification**: primarily **build green** + **SwiftUI `#Preview`s** for each new piece
  (`SpatialBackdrop` light/dark × 2 accents, `GlassCard`, `ReclaimableTile`,
  `ActionPlanTile`, Modern sidebar rows, Modern inspector) and a **manual GUI eyeball**
  at the end (switch skin/accent/mode; visit every route). The existing **48 Core tests**
  are the regression guard. Little new pure logic exists (tiles read existing `env`
  fields); if any pure helper emerges (e.g. action-plan share math) it goes to
  `DiskGalleryCore` with a unit test.

## 8. Risks / mitigations

- **Sidebar material override** (§2 caveat) — the finickiest bit; graceful near-miss
  fallback defined.
- **List background transparency** across routes — `.scrollContentBackground(.hidden)` is
  the supported API; verify per route in previews/build.
- **Contrast in light mode** — glass over a light backdrop can wash out; the
  `.regularMaterial` + hairline + accent borders preserve separation; check in previews.
- **Scope** — many views touched. Mitigated by the shared layer (each route is a 1–2
  modifier change) and a phased plan (foundation → sidebar → workspace/inspector → routes).

## 9. Affected files

- **New** (`DiskGallery/Views/Modern/`): `ModernBackdrop.swift`, `ModernGlass.swift`
  (GlassCard + `.glassCard()` + `.modernListChrome()`), `ModernRows.swift`,
  `StatTiles.swift`.
- **Modify**: `DiskGallery/App/DiskGalleryApp.swift` (ContentView backdrop),
  `DiskGallery/Views/LibrarySidebarView.swift`, `DiskGallery/Views/VolumeBrowserView.swift`,
  `DiskGallery/Views/EntryDetailView.swift`, `DiskGallery/Views/DuplicatesView.swift`,
  `DiskGallery/Views/ActionPlanView.swift`, `DiskGallery/Views/TransferPlannerView.swift`,
  `DiskGallery/Views/SearchResultsView.swift`, `DiskGallery/Views/TaggedListView.swift`.
- (maybe) `DiskGalleryCore` — only if a pure helper emerges.
- `README.md` — note the Modern look now spans the whole interface.
