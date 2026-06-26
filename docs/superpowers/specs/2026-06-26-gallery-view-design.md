# DiskGallery — Gallery View (offline contact sheet) + Modern strip

**Date:** 2026-06-26
**Status:** Approved design — ready for implementation plan(s)
**Implement on:** a dedicated branch off `feature/execution-engine` (so the whole stack — classic-only-declutter → execution-engine → gallery — can merge down together)

## Background & motivation

DiskGallery's name promises a *gallery*, but every view today is a list of filenames + telemetry — "the name writes a check the UI doesn't cash" (`design/disk-gallery/chats/chat5.md`). For its target user (photographers/videographers/archivists), the missing piece is **seeing the work, even when the drive is in a drawer**, and tagging *"while looking at the photo, not the filename"* — the view that makes triage fast. This is the deciding-half complement to the now-complete execution engine (the doing-half).

Current constraints: no thumbnails are captured today; the `Scanner` is strictly read-only directory enumeration; `FileCategory` classifies by extension (photos / raw / video / documents); the catalog lives in `~/Library/Application Support/DiskGallery/`. The app is Classic-only (Modern frozen).

## Decisions (made during brainstorming)

1. **Thumbnail model:** generated **at scan time, opt-in per file type**, cached locally → the gallery is **fully browsable offline** (the app's core identity).
2. **Storage:** **sidecar image files** in App Support, referenced from the catalog by a lean key — the catalog stays small & portable.
3. **Scope:** the **full chat5 vision** (contact sheet + drive shelf + 6 file types + filter chips + grouping + inline tagging), delivered via **staged plans**.
4. **Gating:** **free** (browsing/triage; consistent with "view/catalog free, bulk+automate Pro").
5. **Classic-native**, and to add a clean top-level destination, **strip the frozen Modern UI first** (Stage 0).

## Stage 0 — Modern strip (prerequisite)

Physically remove the frozen Modern skin so Classic is the sole UI and the navigation switch is Classic-only (a new `Gallery` destination then needs no Modern compile-stub). Scope:
- **Delete** `DiskGallery/Views/Modern/` (all Modern pages, `ModernWorkspace`, `ModernSidebar`, `ModernGlass`, OLED hero, stat tiles, etc.), `DiskGallery/Views/OLEDDisplayView.swift`, and `DiskGallery/Support/ModernTokens.swift`.
- **Relocate** `UnifiedComparePanel` out of `Views/Modern/UnifiedCompare.swift` (Classic's detail column uses it) to a non-Modern file (e.g. `Views/UnifiedComparePanel.swift`).
- **Keep** `Support/AccentPalette.swift` (the accent applies to Classic too).
- **Collapse Modern branches in shared views:** remove the `modernListChrome(_:)` / `glassCard()` helpers (defined in `ModernGlass.swift`) and their call sites in Classic views; simplify `ContentView` to the `classicSplit` path only (drop `modernSplit`, the `modern` bool, `SpatialBackdrop`, `modernWindowChrome`); remove the now-dead `env.theme.skin == .modern` checks.
- **Remove the `Skin` concept** (`Theme/ThemeModel.swift` `Skin` enum, `ThemeStore.skin`, `OLEDLayout`, `oledLayout`) now that there's one UI — and the Settings remnants already hidden in the nav-declutter milestone.
- **`SidebarItem`** keeps its cases, but with `ModernWorkspace` gone, the **Classic `ContentColumn` is the only router** — adding `.gallery` later touches one Classic switch.
- **Exact site enumeration is done at plan time** (the shared code changed since the original analysis); the plan greps every `Modern*` / `glassCard` / `modernListChrome` / `skin` reference and removes/relocates each. Gate: build green + 168 tests still pass + app smoke (Classic unaffected).

This is a mechanical removal (~4,000 LOC) with no behavior change to Classic. Net result: a single, lean UI.

## Architecture — Gallery (`DiskGalleryCore/Thumbnails/` + Classic views)

A new logic module plus Classic UI:
- **`ThumbnailService`** (`catalog.thumbnails`) — generate, cache, retrieve, and freshness-check thumbnails.
- **`thumbnail` table** (GRDB migration v8): `volumeKey`, `relPath`, `cacheFile`, `srcModifiedAt`, `srcSize`, `generatedAt`. A *reference* only — bytes live as sidecar files at `~/Library/Application Support/DiskGallery/thumbnails/<hash>.heic` (hash of `volumeKey|relPath`).
- **Per-drive preview-types** config (which `FileCategory`s to generate) — persisted as a JSON-encoded `previewTypes` text column on `volume` (added in migration v8; mirrors how `volume.hardware` already stores JSON), defaulting to `[photos, raw]`. Surfaced as chat5's "Scan cache N/6".

## Thumbnail generation & cache

- **Engine:** `QLThumbnailGenerator` (QuickLook) — real thumbnails for Photos, RAW, Video (poster frame), PSD, PDF (first page). **Honest caveat:** QuickLook gives audio a generic icon/album-art, *not* a waveform (the mockup's waveform was a mock); audio and any type QuickLook can't render show a **type-glyph tile**.
- **Generation pass:** a new pass, **separate from the read-only `Scanner`**, that reads the just-scanned selected-type files (drive connected) and writes only to the App Support cache — it never mutates the drive (`MutationGuardTests` keeps guarding the Scanner). Bounded concurrency, cancellable, progress reported alongside the scan.
- **Size:** thumbnails capped (~512px longest edge, HEIC) to bound total cache size (~hundreds of KB each).
- **Freshness:** keyed by `volumeKey`+`relPath`; a re-scan regenerates an entry whose `srcModifiedAt`/`srcSize` changed.
- **Clearable:** the whole sidecar dir + `thumbnail` table can be cleared/rebuilt independently (it's a cache).

## Scan-time type selection

When scanning, a control (chat5's "Scan cache" popover) selects which file types to generate previews for, persisted per drive. Uncached types still appear in the catalog and render as **locked/glyph placeholders**; enabling a type re-indexes that drive.

## Gallery UI (Classic-native, free)

A top-level **Gallery** sidebar destination (`SidebarItem.gallery`, routed in Classic `ContentColumn`):
- **Drive-shelf header:** a row of drive cards (thumbnail "spine", fill bar, online/offline dot, file count) — click to filter the sheet to that drive.
- **Contact-sheet grid:** a virtualized `LazyVGrid` of tiles. Each tile shows the cached thumbnail (or a type glyph) plus the distinctive signals: the **Keep/Delete/Review dot**, a **duplicate badge (×N)** (from `DuplicateEngine`), and **drive provenance**.
- **Inline tagging:** the existing Q/W/E (decisions) + 1–7 (Finder colors) shortcuts act on the current selection; single-click selects, ⌘/⇧-click multi-selects — so the user tags while looking at the image.
- **Filter chips:** All / Photos / RAW / Video / Docs / Audio, with a live "N of M cached" count.
- **Group-by:** shoot (folder) / drive / type.
- **Offline:** the grid renders entirely from the local cache; drives need not be connected.

## Testing

- `ThumbnailService` cache + freshness logic is unit-tested in `DiskGalleryCore` (temp cache dir + fixture files: store→retrieve, stale-on-mtime-change, miss→nil). The QuickLook call itself is a thin wrapper, verified by build + smoke.
- The Modern strip is verified by build + the full test suite staying green + a Classic smoke pass.
- Gallery views are build + manual smoke (no app unit-test target).

## Staged delivery (full vision, built incrementally)

One spec; each stage a plan that lands verified-green:
- **Stage 0 — Modern strip.** (Above.) Classic becomes the sole UI.
- **Stage A — Thumbnails module.** `thumbnail` table (migration v8) + sidecar cache + `ThumbnailService` + the scan-time generation pass + per-drive preview-type selection. Non-UI foundation; unit-tested cache logic.
- **Stage B — Gallery grid.** The `Gallery` destination + contact-sheet `LazyVGrid` + tiles (thumbnail/glyph + tag dot + dup badge + drive) + inline tagging + placeholders. Proves browse-thumbnails-offline + triage.
- **Stage C — Filters, grouping, drive shelf.** Media-type filter chips, group-by, the drive-shelf header, and the "N of M cached" / scan-cache affordances.

## Non-goals

- No fake audio waveform (QuickLook icon/glyph instead) — manage expectations vs the mockup.
- No image editing, full-screen viewer, or slideshow (out of scope; triage-focused).
- No thumbnails in the catalog export (they're a local cache; regenerate on scan). A future enhancement could bundle them.
- No re-introduction of Modern.

## Risks

- **Generation cost** for large drives — mitigated by opt-in types, bounded concurrency, cancellation, and progress; it runs while connected, not on the offline path.
- **Cache size** — bounded by the size cap + opt-in types; clearable.
- **Modern strip breakage** — mitigated by relocating `UnifiedComparePanel`, keeping `AccentPalette`, and the build+test+smoke gate; Classic behavior is unchanged.
