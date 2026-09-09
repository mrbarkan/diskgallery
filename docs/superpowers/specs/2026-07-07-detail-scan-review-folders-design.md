# DiskGallery — Detail Scan for Review folders

**Date:** 2026-07-07
**Status:** Approved design — implementing inline

## Background

`Review` is the yellow "look closer / undecided" action tag, appliable to any
file or folder. When you flag a *folder* Review, you want to actually see
what's in it before deciding. Today there's no way to generate previews for
one folder on demand, nor to view just that folder in the Gallery. "Detail
Scan" fills that gap: generate previews for the flagged folder's media, then
drop you into the Gallery scoped to exactly that folder.

## Decisions (from brainstorming)

1. **Trigger — two surfaces:** a "Detail Scan" button in the inspector
   (`EntryDetailView`) when the selected entry is a Review-tagged folder on a
   connected drive, **and** a right-click "Detail Scan" item in the file
   browser (`FolderView`) on the same condition.
2. **What it generates:** thumbnails for the visual media set
   **[photos, raw, video]** across the folder's whole subtree — regardless of
   the drive's normal preview-type config (Detail Scan = "show me everything
   visual in here"). Reuses the existing `ThumbnailService` engine + progress HUD.
3. **Then:** switch the sidebar to the Gallery, **scoped to that folder** — a
   clearable "📁 FolderName ✕" chip; clearing returns to the full Gallery.
4. **Gating:** free (Gallery/thumbnails are free; no `Feature` gate exists).
5. **Connected required** (reads the real files); disabled/hidden when the
   drive is offline.

## Architecture

### Core (two additive query params + one shared helper)

- **`SQLPattern.childrenPrefix(of:)`** (added to `PathVisibility.swift`, no new
  file) — escapes LIKE metacharacters (`\ % _`) in a folder relPath and appends
  `/%`, so a folder literally named e.g. `2024_trip` can't false-match
  `2024Xtrip`. Used with `LIKE ? ESCAPE '\'`.
- **`ThumbnailService.entriesNeedingPreview(volumeId:categories:underRelPath:)`**
  — optional `underRelPath: String? = nil`; when non-empty, adds
  `AND e.relPath LIKE ? ESCAPE '\'` (subtree scope).
- **`GalleryService.items(…, underRelPath: String? = nil)`** — same subtree
  filter, so the grid can show just the folder.

### App

- **`GalleryFolderScope`** (`{ volumeId, relPath, name }`) + `galleryFolderScope`
  on `AppEnvironment`.
- **`AppEnvironment.detailScan(folder:)`** — resolves the current drive via
  `currentVolumeSummary`, requires it connected, runs a scoped preview pass
  (forced media categories, `underRelPath: folder.relPath`) via a shared
  private `generatePreviews(summary:categories:underRelPath:onComplete:)` that
  `generateThumbnails(for:)` is refactored to also call; on completion sets
  `galleryFolderScope` and `selection = .gallery`.
- **`GalleryView`** — when `galleryFolderScope` is set, use its `volumeId` +
  `relPath` (`underRelPath`) for `gallery.items`, show the scope chip (✕ clears
  it), and include the scope in the reload `.task(id:)`. Tapping a drive card
  in the shelf clears the folder scope.
- **`EntryDetailView`** (`EntryInspector`) — "Detail Scan" button shown when
  `entry.isDir && annotation?.tag == .review && env.isSelectedVolumeConnected`.
- **`FolderView`** (`VolumeBrowserView`) — context-menu "Detail Scan" item for a
  single Review-tagged folder target on a connected drive.

## Testing

- **Core (append to existing files):**
  - `ThumbnailTests`: `entriesNeedingPreview(underRelPath:)` returns only the
    subtree; a sibling folder sharing a prefix (incl. an `_` to guard the LIKE
    escaping) is excluded.
  - `GalleryTests`: `items(underRelPath:)` scopes to the subtree.
- **Manual smoke (owner):** tag a folder Review → Detail Scan (inspector +
  right-click) → previews generate → lands in the Gallery scoped to the folder;
  ✕ clears; offline drive disables the action.

## Out of scope

- Detail Scan on files (folders only) or on non-Review entries.
- Hashing / stats (that was a different brainstorm option; not chosen).
