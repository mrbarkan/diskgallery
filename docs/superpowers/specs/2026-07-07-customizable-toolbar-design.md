# DiskGallery — Finder-style customizable toolbar + hidden-files fix

**Date:** 2026-07-07
**Status:** Approved design — ready for implementation plan

## Background & motivation

Two things drove this:

1. **The "Hide hidden files" toggle looks broken.** It exists in Settings
   (`ViewPrefsStore.hideHidden`, default on) and its help text promises it hides
   dotfiles "from the browser, search, and duplicates." But it is only ever
   consulted by the cross-drive **All Drives** outline (`UnifiedOutline` →
   `UnifiedBrowserService.merge`). The per-drive file browser
   (`FolderView.load` → `library.children`), the Gallery (`gallery.items`),
   search, and duplicates all query the catalog directly and never filter
   dotfiles. So the toggle works in exactly one place and reads as dead
   everywhere else.

2. **The app has no real header.** Each view hand-builds its own control strip
   (`DriveHeaderBar`, the Gallery `driveShelf` + `controlBar`). There is no
   single, discoverable home for the common actions, and no way for the user to
   pick which controls they see or how they're arranged.

The user asked for "a header, like in Finder, with all the most common options
— toggle labels, large or small icons, customize what's shown, change the
order." That is a precise description of macOS's native **Customize Toolbar…**
sheet, which Finder itself uses.

## Decisions (made during brainstorming)

1. **Native macOS toolbar**, not a hand-rolled header band. SwiftUI's
   customizable toolbar (`.toolbar(id:)` + `ToolbarItem(id:)`) *is* the Finder
   mechanism and gives add/remove, reorder, Icon+Text / Icon-only / Text-only,
   Use-small-size, and persistence for free. We only declare the items.
2. **Global** — one toolbar for the whole window, items grey out when they don't
   apply to the current view (Finder-style), rather than a per-view toolbar.
3. **Migrate duplicated controls** into the toolbar rather than leaving the old
   in-view bars fully intact (avoids two copies of Re-scan / Filter / Group).
4. **Fold the hidden-files fix into this work**, since the new toolbar hosts a
   live "Hide Hidden" toggle and the fix is what makes that toggle mean
   anything.

## Architecture

### 1. The toolbar (native)

A single `.toolbar(id: "dg.main")` declared on the `NavigationSplitView` in
`ContentView`, keeping the existing `.windowToolbarStyle(.unified)`. Verify it
renders alongside `.windowStyle(.hiddenTitleBar)` (it should — the toolbar
occupies the unified title area); only drop `hiddenTitleBar` if it doesn't.

The native customization sheet (reached via right-click → Customize Toolbar…,
wired automatically once items have ids + `.customizationBehavior`) provides:
add/remove, drag-reorder, **Show: Icon and Text / Icon Only / Text Only**, **Use
small size**, and per-toolbar-id persistence. No custom code for any of it.

### 2. The items ("our options")

Each is a `ToolbarItem(id:)` with a stable id and a sensible default visibility.
Contextual items are `.disabled` (greyed) when not applicable:

| id | Control | Enabled when | Notes |
|----|---------|-------------|-------|
| `sidebar` | Sidebar toggle | always | native |
| `scan` | New Scan | always | pick a volume/folder → scan |
| `rescan` | Re-scan | a connected drive is selected | moved out of `DriveHeaderBar` |
| `changes` | Changes… | a drive is selected | moved out of `DriveHeaderBar` |
| `filter` | Media filter (menu) | Gallery selected | moved out of Gallery `controlBar` |
| `group` | Group-by (menu) | Gallery selected | moved out of Gallery `controlBar` |
| `tileSize` | Tile size small/large | Gallery selected | new — content "large/small icons" |
| `labels` | Show tile labels | Gallery selected | new — content "toggle labels" |
| `hidden` | Hide Hidden toggle | always | drives `viewPrefs.hideHidden` |
| `search` | Search field | always | global |

`tileSize` and `labels` cover "large/small icons" and "toggle labels" at the
*content* level; the native customize sheet covers them at the *toolbar-button*
level. Either interpretation is satisfied.

Default-visible set is a Finder-like subset (sidebar, rescan, changes, filter,
group, tileSize, hidden, search); the rest are available in Customize.

### 3. Shared state

Gallery's `filter` and `grouping` are `@State` in `GalleryView` today. To let
the toolbar drive them, lift them — plus two new prefs `tileSize`
(`.small`/`.large`) and `showTileLabels` (Bool) — into a shared `@Observable`
(extend `ViewPrefsStore`, persisted in `UserDefaults`). `GalleryView` reads/
writes the same store, so grid and toolbar stay in sync and survive relaunch.
`hideHidden` already lives in `ViewPrefsStore`.

`GalleryTile` gains: tile size scales the grid `GridItem` min/max; `showTileLabels`
gates the filename + drive lines.

### 4. Hidden-files fix (Core)

Thread `hideHidden: Bool` (default `false`) into the four Core queries that
ignore it today, filtering with the existing `PathVisibility` rule (a path
component beginning with `.`):

- `LibraryService.children(parentId:snapshotId:)` — one level: `AND name NOT LIKE '.%'`.
- `GalleryService.items(...)` — arbitrary depth: exclude any relPath component
  starting with `.` (`relPath NOT LIKE '.%' AND relPath NOT LIKE '%/.%'`).
- `SearchService` entry query — same relPath rule.
- `DuplicateEngine.duplicateSets(...)` — same relPath rule.

Callers (`FolderView`, `GalleryView.load`, search UI, `DuplicatesView`) pass
`env.viewPrefs.hideHidden`, exactly as `UnifiedOutline` already does. The
`hidden` toolbar toggle and the Settings toggle then both take effect
everywhere, matching the Settings help text.

Keep the SQL filter behind the `hideHidden` flag so the read-only /
catalog-completeness invariant is untouched — files are still catalogued, only
filtered from display.

### 5. Existing bars

- `DriveHeaderBar`: drop its Re-scan / Changes buttons (now toolbar items); keep
  the name, info line, hardware badge, and capacity gauge.
- Gallery `controlBar`: drop the filter chips and group picker (now toolbar
  items); keep the "N of M cached" count. `driveShelf` is unchanged.

## Testing

- **Unit (Core):** for each of the four queries, a test asserting a seeded
  dotfile (e.g. `.DS_Store`, and a file under `.Trashes/`) is excluded when
  `hideHidden: true` and present when `false`. This is the regression guard for
  the reported bug.
- **Manual smoke:** toolbar renders; Customize Toolbar… reorders / toggles
  labels / small size and persists across relaunch; contextual items grey out
  off-view; Hide Hidden toggle live-updates the browser, Gallery, search, and
  duplicates; Gallery tile size + labels toggle work.

## Out of scope

- Per-view *separate* toolbars (one global toolbar with contextual enabling).
- New actions beyond the table above (no share/export/print buttons invented).
- Column/list view switching (Gallery is the icon view; the drive browser stays
  a list).
