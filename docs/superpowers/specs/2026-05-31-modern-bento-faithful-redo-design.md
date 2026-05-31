# DiskGallery — Modern Bento, Faithful Redo (Design Spec)

_2026-05-31_

## 1. Why this exists

The first Modern/OLED implementation diverged from the mockup. This spec is a **pixel-faithful port** of the Claude Design handoff bundle (`Deg8Tpn8khjHJv124WXi_w`) into the native SwiftUI app. The bundle's `DiskGallery.html` + `diskgallery.css` are the **source of truth**; the two chat transcripts confirm intent (a bento/glass/OLED workspace, this exact SwiftUI app as the target, SF fonts acceptable).

**Approved decisions (this session):**
- **Two-pane bento** — Modern becomes `sidebar + one workspace`; OLED + topbar span full width above browser **and** inspector. (Inspector stops being a separate split-view column.)
- **All Modern screens** — the drive browser is rebuilt exactly to the mockup; Duplicates / Search / Action Plan / Transfer Planner / tagged lists adopt the same bento shell.
- **Full-bleed** — hide the macOS title bar in Modern; traffic-lights float over the canvas.

## 2. Invariants (do not break)

- **Classic is sacred.** Every Modern branch is gated on `env.theme.skin == .modern` (`private var modern: Bool`). The Classic path = original code verbatim: 3-column `NavigationSplitView`, standard title bar, original `Form`/`List` views.
- **Core logic untouched.** No changes to `DiskGalleryCore` behavior; the app stays read-only on drives. `DiskGalleryCoreTests` must stay green (48 tests).
- **Fonts:** system UI font (for Hanken Grotesk) + `.monospaced` design / SF Mono (for JetBrains Mono). User confirmed SF is fine.
- **No new persisted theme axes.** Theme model stays 4-axis: `Skin`, `Accent` (graphite/violet/blue/green/amber/coral), `AppearanceMode`, `OLEDLayout`. The mockup's "glass blur" slider is **out of scope** (Material is discrete) — use `.regularMaterial`.

> Note: the mockup's accent set is violet/blue/green/amber/coral (5). The app additionally has **graphite** (the Classic default). Graphite stays selectable; in Modern it renders as a neutral accent. The 5 mockup accents must match the hex below exactly.

## 3. Design tokens — EXACT

### 3.1 Dark mode (default)
| Token | Value |
|---|---|
| bg-0 / bg-1 / bg-2 | `#08090C` / `#0C0E13` / `#11141A` |
| glass / glass-2 / glass-3 | `white @ 0.045` / `0.072` / `0.10` |
| hair / hair-2 | `white @ 0.085` / `0.16` |
| inset | `black @ 0.45` |
| ink / ink-2 / ink-3 / ink-4 | `#EDEFF4` / `#A6ABB7` / `#6C7280` / `#474D5B` |
| oled / oled-2 | `#040506` / `#090B0F` |
| oled-ink / -2 / -3 | `#F3F1E9` / `#F3F1E9 @ 0.62` / `@ 0.40` |
| ok / warn / bad | `#4ADE80` / `#F7B955` / `#F8736B` |

### 3.2 Light mode (`[data-mode="light"]`)
| Token | Value |
|---|---|
| bg-0 / bg-1 / bg-2 | `#E9EAEF` / `#EEF0F4` / `#F4F6F9` |
| glass / glass-2 / glass-3 | `white @ 0.66` / `0.82` / `0.92` |
| hair / hair-2 / inset | `#0F1423 @ 0.10` / `0.16` / `0.08` |
| ink / ink-2 / ink-3 / ink-4 | `#1A1D26` / `#535A68` / `#838A98` / `#AAB0BC` |
| backdrop glow opacity | `0.5` |
| OLED | stays dark in both modes (it's a screen) |

### 3.3 Finder colors (fixed, both modes)
red `#F8736B` · orange `#F6A23C` · yellow `#F5CF52` · green `#5FD38A` · blue `#5AA2FF` · purple `#B78CFF` · gray `#8A909D`

### 3.4 Accents — EXACT (`accent / accent-2 / accent-deep / glow / soft / ink`)
| Accent | accent | accent-2 | accent-deep | glow | soft | ink (text on fill) |
|---|---|---|---|---|---|---|
| **violet** (default) | `#A78BFF` | `#8F6CFF` | `#6F4CE0` | `167,139,255 @0.45` | `@0.16` | `#15101F` |
| blue | `#5AA2FF` | `#3D86F0` | `#2F6AD6` | `90,162,255 @0.45` | `@0.16` | `#04101F` |
| green | `#54E0A0` | `#2FC586` | `#1EA372` | `84,224,160 @0.42` | `@0.16` | `#04130C` |
| amber | `#F7C14E` | `#EDA52F` | `#CF851E` | `247,193,78 @0.42` | `@0.16` | `#1C1304` |
| coral | `#FF855F` | `#F56640` | `#D6492A` | `255,133,95 @0.45` | `@0.16` | `#1D0C05` |
| graphite | keep existing neutral palette (Classic default; not in mockup) |

### 3.5 Geometry & type
- radius: **20** (cards/sidebar/OLED) · **12** (scan button) · **9** / **11** (nav items, frow, tagbtn, tbtn) · **999** (pills)
- card shadow: `0 18px 44px -22px black@0.8` + inset top highlight `0 1px 0 white@0.05`
- fonts: UI = system; mono = `.system(.<size>, design: .monospaced)`

### 3.6 color-mix adaptation
CSS uses `color-mix(in oklab, COLOR X%, transparent)`. Port as `Color(COLOR).opacity(X/100)` (e.g. chip fills at 16%, active tag fills at 14%). Fixed `accent-soft` already has an exact rgba — use it directly. This is an approximation (oklab≠alpha) but acceptable per the design chat.

## 4. App shell

### 4.1 Root branch (`ContentView`)
```
if modern → NavigationSplitView { Sidebar } detail: { ModernWorkspace() }   // TWO columns
else      → existing 3-column NavigationSplitView (unchanged)
```
- Sidebar column width: min 248 / ideal **272** (mockup is 272). Backdrop (`SpatialBackdrop`) behind the whole thing in Modern.
- `.tint(accent)`, `.preferredColorScheme(mode.colorScheme)` as today.

### 4.2 Full-bleed window chrome (Modern only)
- A `WindowAccessor` (`NSViewRepresentable` reaching `view.window`) sets, when Modern:
  `titlebarAppearsTransparent = true`, `titleVisibility = .hidden`, `styleMask.insert(.fullSizeContentView)`, `isMovableByWindowBackground = true`.
- When Classic: restore (`titlebarAppearsTransparent = false`, `titleVisibility = .visible`, remove `.fullSizeContentView`).
- **Traffic-light clearance:** in Modern, the sidebar's top content gets an extra **top inset ≈ 28pt** so the brand row clears the floating window buttons.

### 4.3 ModernWorkspace router
```
switch env.selection {
  case .volume(id):  VolumeBentoWorkspace(summary)      // topbar + OLED + bento(browser+stats | inspector)
  case .duplicates:  RouteBentoWorkspace("Duplicates", icon) { DuplicatesContent() }
  case .search:      RouteBentoWorkspace("Search", icon, searchFocused) { SearchContent() }
  case .plan:        RouteBentoWorkspace("Action Plan", icon) { ActionPlanContent() }
  case .transfer:    RouteBentoWorkspace("Transfer Planner", icon) { TransferContent() }
  case .tagged(tag): RouteBentoWorkspace(tag.label, icon) { TaggedContent(tag) }
  case nil:          ContentUnavailableView(...)
}
```
- `RouteBentoWorkspace` = topbar(title + search pill, **no** Display/Re-scan cluster) + bento(`[content card | inspector card]`, columns 1.55fr/1fr, single row).
- `VolumeBentoWorkspace` = the mockup (below).

## 5. Workspace layout metrics
- App padding **14**, gap **14** between sidebar and workspace.
- Workspace = vertical stack, gap **14**: `topbar`, `OLED` (volume only), `bento` (fills remaining).
- Volume bento grid: columns **1.55fr / 1fr**, rows **1.12fr / 0.88fr**, areas `browser inspector` / `stats inspector` (inspector spans both rows). Implement with an `HStack(spacing:14)` of `[VStack(spacing:14){ browser; stats }]` (1.55) and `[inspector]` (1.0); stats row = `HStack(spacing:14){ reclaim; plan }`. Use `GeometryReader`/`layoutPriority` + `.frame(maxWidth/Height:.infinity)` with the 1.55:1 width split.

## 6. Sidebar (exact)
- Container: glass card, hair border, radius 20, blur. Flex column, clipped.
- **Brand** (`padding 18/18/14`, +28 top inset in Modern for traffic lights): 36×36 squircle (radius 11) filled `linear-gradient(150°, accent → accent-deep)`, border `hair-2`, inner top highlight; SF symbol `externaldrive`/grid glyph in `accent-ink`. Title "DiskGallery" 16pt/700; sub "OFFLINE CATALOG" mono **8.5px**, tracking 0.22em, uppercase, ink-3.
- **Scan button** (`margin 0/14/12`, height **38**, radius 12): `linear-gradient(180°, accent → accent-2)`, text `accent-ink`, mono **10.5px**, tracking 0.18em, uppercase, 700; glow shadow. Label "SCAN A DRIVE" + plus-in-rect icon. Action = existing scan picker.
- **Nav** scrollable, `padding 4/10/14`.
  - Section header: mono 8.5px, tracking 0.22em, uppercase, ink-4, `padding 8/10/6`; optional trailing count (e.g. "Drives 3 / 5" with the count in ink-3).
  - Sections + items (match counts to real data; mockup figures are placeholders):
    - **Library**: Duplicates (badge = reclaimable total), Search.
    - **Plan**: Action Plan (badge = tagged count), Transfer Planner.
    - **Action Tags**: Keep / Delete / Review / Move / Backup (badge = per-tag count). Icons per tag.
    - **Drives N / M**: one drive row each.
  - **nav-item**: grid `18 / 1fr / auto`, gap 11, padding 8/11, radius 9; icon ink-3, label 13.5pt/500 ink-2; badge = mono 9.5px on glass-2 pill (radius 999), ink-3. Hover → glass-2 + ink. **Selected (`.on`)** → bg `accent-soft`, inset 1px border `accent@0.40`, icon + badge → accent (badge bg `accent@0.18`).
- **Drive row** (`padding 9/11`, radius 9, margin-bottom 2): top line = status dot (8px; connected = `ok` + glow, disconnected = ink-4) + name (13pt/600, truncating) + optional incomplete glyph (warn). Sub = mono 9px ink-3 (`"3.16 TB · 248,193 files"`, or warn text "Incomplete — resume to finish"). Minibar = 4px track (inset bg) with fill `accent` (or `bad` when ≥ ~92% full, class `.full`). Selected drive `.on` → glass-2 + inset hair-2 border.

## 7. Topbar (exact)
- Row, align center, gap 14, `padding 2/2/0`. Height ≈ 36.
- **Breadcrumbs** (volume route): leading drive icon (ink-3, 15px) + segments separated by `/` (sep = ink-4). Non-current segs = ink-3; **current** = ink, 600. Built from the real folder path; clicking an ancestor navigates up. Other routes: a single title segment (the route name).
- **Search pill**: width ~260, height **36**, radius 999, bg glass, 1px hair border, ink-3; magnifier (15px) + "Search all drives" (13pt) + trailing `⌘K` kbd (mono 10px on glass-2, radius 6). Click / ⌘K → Search route.
- **tbtn cluster** (volume route only), gap 8:
  - **Display** (`padding-left 10`): refresh-arrows icon + "Display" + **mode chip** = mono **10px**, tracking 0.12em, uppercase, 700, accent text on `accent-soft`, radius 7, showing `TELEMETRY`/`GAUGE`/`MINIMAL`. Click → cycle OLED layout (`cycleOLEDLayout()`).
  - **Check changes**: clock-arrow icon + label. Click → present `ChangesView`. Optional: spinner → "Up to date" flash (`ok` color) for ~1.2s (cosmetic; safe to defer).
  - **Re-scan**: drive-refresh icon + label. Click → `env.rescan(volume:)`. Shown only when the drive is connected. Optional spinner while scanning.
  - tbtn base: glass bg, 1px hair, radius **11**, height **36**, padding 0/12, label 12.5pt/600 ink-2; hover → glass-2 + ink; icon 16px.

## 8. OLED hero (verify against existing `OLEDDisplayView`)
Chassis: radius 20, height **216** (fixed), bg `radial(accent 9% top-left) + linear(oled-2 → oled)`, black border, layered inset + glow shadows incl. `0 0 50px -16px accent-glow`; scanline overlay (`repeating-linear-gradient 0/1px/3px white@0.022`, screen blend) + vignette (`inset 0 0 80px 10px black@0.55`). Mono font, `oled-ink`.
- Three layouts crossfade **in place** (chassis never resizes): active = opacity 1 / no transform; entering rises from `translateY(14) scale(.985) blur(7)`; leaving → `translateY(-10) scale(.99) blur(6) brightness(1.6)`; ~0.42–0.5s eased. Plus a one-shot **flash** (accent bloom) + **sweep** (2px accent line travels top→bottom, glow) on switch.
- **Telemetry**: top row = "● Selected Drive" accent tag + name (12px, 0.1em, uppercase) on left; right = pills (`live` = ok ring + dot "Connected"; "APFS · ENCRYPTED"; "Scanned 2d ago"). Cells grid `1.3fr + 4×1fr`, dividers `oled-ink@0.10`; each cell: k (oled-k 8.5px) / v (**30px**/700, unit 13px oled-ink-2; `.accent` = accent + glow; `.ok` = ok) / sub (oled-sub 8.5px). Bottom bar grid `auto/1fr/auto`: "VOL UUID …" + capbar (9px, fill `linear(accent-2→accent)` + glow) + path (`/Volumes/…` with bold accent tail).
- **Gauge**: grid `168 + 1fr`, gap 28. Ring svg 168, r72, stroke 13, track `oled-ink@0.10`, progress `accent` + drop-shadow glow, `stroke-dashoffset` set from % (circumference ≈ 452.4). Center: pct **38px** + "Used". Right: tag, "X TB used" (gauge-name 26px/700), sub line, 3 stat columns (19px values).
- **Minimal**: tag + connected pill on top; big name **40px/800**; full-width capbar (height 11); stats row (16px values + 11px units), reclaimable in `ok`.

All values above are for verification — keep the existing port where it already matches; correct any deltas.

## 9. Browser card (volume)
- GlassCard. **card-h**: title = folder icon (accent, 16px) + folder name (13pt/700); meta = mono 9.5px ink-3 `"7 items · 1.89 TB"`. Padding `14/26/12/16`.
- **List adaptation:** keep SwiftUI `List` (preserves multi-select ⌘/⇧, keyboard nav, context-menu tagging, double-click-to-open via `primaryAction`). Style: `.listStyle(.plain)`, `.scrollContentBackground(.hidden)`, custom row content, selection painted via `.listRowBackground`. List sits inside the card body (`padding 2/18/10/12`).
- **frow** content: ficon (20px; folder → accent, file → ink-3) · fname (13.5pt/500; `.ext` portion ink-3) · ftags (chips + color dot, gap 7) · fsize (mono 11.5px ink-2, right, min 66). Row padding 9/12, radius 11. Hover → glass-2. **Selected** `.listRowBackground` → `accent-soft` + inset `accent@0.42` border.
- **chip**: mono 9px, tracking 0.12em, uppercase, 700, padding 3/8, radius 7. keep=ok / delete=bad / review=warn / backup=blue / move=purple, each text=color on `color@0.16` fill.
- **cdot**: 10px circle (finder color) with 2px glass ring.

## 10. Inspector card (volume + all routes)
- GlassCard. **card-h**: info-circle icon (accent) + "Inspector"; meta = "N selected".
- Body scrolls (`padding 0/16/16`):
  - **insp-hero**: 52×52 squircle (radius 14) `linear(150°, accent@30% over bg-2 → bg-2)`, border hair-2, glyph (folder/doc) in accent (26px); title 16pt/700; kind = mono 9.5px uppercase ink-3 (`"Folder · 12,408 items"` / file type).
  - **spec** grid `84 / 1fr`, gap 7/12, border-top hair, padding 12/0: dt = mono 9px uppercase ink-3; dd = mono 12px ink (`.size` dd = accent). Rows: Size, On disk (files only), Modified, Path (truncating middle).
  - **insp-sec-h** "Action Tag": mono 9px tracking 0.18em uppercase ink-3, border-top hair, padding 12/0/9.
  - **tagbtns**: grid **3 columns**, gap 7 → 6 buttons. The `Tag` model already has all five action tags (`keep/delete/review/move/backup` + `none`), so no model change. **Hardcode the display order to the mockup** — Keep, Delete, Review, Move, Backup, None — which differs from `Tag.actionTags` (`[.keep, .move, .backup, .review, .delete]`); don't drive the grid off `actionTags`. Each = column (icon 16px over mono 8.5px uppercase label), bg glass-2, radius 11, padding 9/6, ink-2. **Active** (`.on.<tag>`) = tag color text + 1px tag border + `color@0.14` fill. (`None` clears.) Tag→color: keep=ok, delete=bad, review=warn, move=purple, backup=blue.
  - **insp-sec-h** "Finder Color".
  - **swatches**: flex, gap 9. 8 items: `none` (24px glass-2 circle + slash glyph ink-3) then red/orange/yellow/green/blue/purple/gray (24px filled circles, inner dark hairline). **Active** = `outline: 2px solid ink, offset 2` (⚠ ink, **not** accent — supersedes the earlier Phase-1 accent-ring decision).
  - **finder-note**: row, ok color, 11px, cloud-check icon — "Written to the file as Finder tags" when connected; otherwise the existing "saved in catalog" secondary note.
- Implementation: refactor `EntryInspector`/`MultiSelectInspector` Modern bodies into reusable card content (`ModernInspectorContent`) used here; the Classic `Form` path stays for the Classic detail column.

## 11. Stat tiles (volume)
Two tiles side-by-side (each a card, padding 16, flex column, equal width).
- **Reclaimable** (`tile-reclaim` bg = `linear(150°, accent@12% over glass → glass)`): lbl "Reclaimable · Duplicates" (mono 9.5px, 0.2em, uppercase, ink-3); **big-num** = `Format.bytes(reclaimable)` at **48px/800**, accent, unit (e.g. "GB") 21px/700 ink-2; **stack-bar** 8px (three segments — accent / blue / ink-4 — proportions from duplicate breakdown, fallback 46/30/24); tile-row (margin-top auto): sub "`N` sets across `M` drives" (ink-2, bold numerals ink) + "View →" lbl. Tap → Duplicates route.
- **Action Plan** (`tile`): lbl "Action Plan · `N` tagged"; **plan-rows** (gap 11): per tag (Keep/Backup/Review/Delete) a grid `70 / 1fr / auto` = label (8px square pdot in tag color + 12px/600 ink-2) + track (7px, inset bg, fill in tag color, width = share) + amt (mono 11px ink, e.g. size or count, min 52, right). tile-row: "`N` drives to connect" + "Open plan →". Tap → Action Plan route.

## 12. Other routes (bento shell)
Each = `RouteBentoWorkspace` = topbar(route title + search pill) + bento `[content card | inspector card]` (columns 1.55fr/1fr). The content card = the route's existing view, restyled to live inside a GlassCard with a `card-h` (icon + title + meta) and `.scrollContentBackground(.hidden)` lists. Inspector card = `ModernInspectorContent` (reused). No OLED. Keep each route's existing behavior; only the chrome changes.
- Duplicates, Search, Action Plan, Transfer Planner, tagged lists.
- Where a route already has a usable Modern treatment, align it to the card/topbar system rather than rewrite its internals.

## 13. Functional wiring summary
| Control | Action |
|---|---|
| Sidebar Scan a drive | existing scan picker |
| Sidebar nav items / drives | set `env.selection` |
| Topbar breadcrumbs | navigate folder ancestors |
| Topbar search / ⌘K | `env.selection = .search` |
| Display button | `env.theme.cycleOLEDLayout()` |
| Check changes | present `ChangesView` |
| Re-scan | `env.rescan(volume:)` (connected only) |
| Inspector tag buttons | `env.applyDecision(tag, to:)` |
| Inspector swatches | `env.applyColor(color, to:)` |
| Reclaimable / Plan tiles | set `env.selection` to `.duplicates` / `.plan` |

## 14. File plan (anticipated)
- `App/DiskGalleryApp.swift` — root skin branch + `WindowAccessor` full-bleed.
- `Views/Modern/ModernWorkspace.swift` — router + `VolumeBentoWorkspace` + `RouteBentoWorkspace`.
- `Views/Modern/ModernTopbar.swift` — breadcrumbs, search pill, tbtn cluster, Display chip.
- `Views/Modern/ModernSidebar.swift` (or extend `LibrarySidebarView`) — glass sidebar to spec.
- `Views/Modern/ModernGlass.swift` — GlassCard, tbtn/scan button styles, chip, mono label, color dot, card header.
- `Views/Modern/StatTiles.swift` — Reclaimable + Action Plan tiles (rebuild to §11).
- `Views/Modern/ModernBrowser.swift` — frow row + list chrome (§9).
- `Views/EntryDetailView.swift` — extract `ModernInspectorContent` (§10).
- `Views/OLEDDisplayView.swift` — verify/align to §8.
- `Support/AccentPalette.swift` / `Colors.swift` — verify exact hex (§3.4), add tokens as needed.
- Each route view — wrap in card chrome for Modern (§12).

## 15. Testing & verification
- `DiskGalleryCore` tests stay green (no Core changes expected).
- App target builds for `macOS,arch=arm64`.
- Visual smoke: launch, confirm against the bundle screenshots (telemetry/gauge/minimal, browser, inspector, tiles, light + dark, each accent), and confirm **Classic is byte-for-byte unchanged** (toggle skin).
- Adversarial review pass before merge (the prior redo under-delivered; a fidelity checklist per component is required).

## 16. Out of scope
- Glass-blur slider (Material is discrete) — fixed `.regularMaterial`.
- Bundling Hanken Grotesk / JetBrains Mono TTFs (SF approved).
- Changing Core scanning / duplicates / tagging logic.
- Redesigning the Settings window (theme controls already live there).
