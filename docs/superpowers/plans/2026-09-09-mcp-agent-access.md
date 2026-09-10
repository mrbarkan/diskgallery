# MCP Agent Access — Implementation Plan

**Goal:** Let an external AI agent (Claude Desktop / Claude Code / any MCP client) read the
DiskGallery catalog — drives, folders, files, thumbnails, duplicates — and propose an
organization by writing annotations (Keep/Delete/Review/Move/Backup + Finder color + note)
that the user reviews in the app. No drive writes, no execution.

**Spec:** `docs/superpowers/specs/2026-09-09-mcp-agent-access-design.md`

**Architecture:** MCP over stdio, JSON-RPC 2.0, hand-rolled with `Codable` (no dependency).
Served by the app binary as a new launcher mode: `DiskGallery --mcp`, mirroring `--scan`.

## Deviation from the spec (decided here)

The spec left open whether the dispatcher lives in the app target or Core. **It goes in
Core** (`DiskGalleryCore/MCP/`): it is pure logic over `Catalog`, Core already links
QuickLook/ImageIO for thumbnails, and mount detection can use `FileManager` +
`VolumeMetadata.read` instead of AppKit. This means it is unit-testable in the **existing**
`DiskGalleryCoreTests` target — no new test target, no app-target test host. The app keeps
only a 3-line `--mcp` branch.

## Global constraints

- **Read-only w.r.t. the filesystem.** The MCP sources never mutate a drive; only the
  catalog DB (annotations) is written. `MutationGuardTests` is extended to cover them.
- **Two-target split:** all logic in Core; the app only branches in `Launcher.main()`,
  polls the change counter, and shows the config snippet in Settings.
- **stdout is protocol-only.** Every log/diagnostic goes to stderr, or the client breaks.
- **New source files → run `xcodegen generate`** before building (the `.xcodeproj` is
  committed).
- **Verify before commit:** Core suite green AND app builds AND a stdio smoke test.

## File map

- New: `DiskGalleryCore/MCP/JSONValue.swift` — minimal dynamic JSON `Codable` value.
- New: `DiskGalleryCore/MCP/MCPServer.swift` — JSON-RPC envelope, stdio loop, dispatch.
- New: `DiskGalleryCore/MCP/MCPTools.swift` — tool schemas + handlers over `Catalog`.
- Modify: `DiskGalleryCore/Data/Migrations.swift` — v9 `meta(key TEXT PK, value TEXT)`.
- Modify: `DiskGalleryCore/Annotations/AnnotationStore.swift` — bump `changeCounter`
  inside the upsert transaction; `public func changeCounter()`.
- Modify: `DiskGallery/App/DiskGalleryApp.swift` — `--mcp` branch.
- Modify: `DiskGallery/App/AppEnvironment.swift` — 2 s poll → `dataVersion += 1`.
- Modify: `DiskGallery/Views/SettingsView.swift` — "Agents" tab with the copy-paste config.
- New: `DiskGalleryCoreTests/MCPTests.swift` — dispatcher tests over a `Fixture` catalog.
- Modify: `DiskGalleryCoreTests/MutationGuardTests.swift` — guard the MCP sources.
- Modify: `README.md` — how to connect a client.

## Task 1 — Change counter (Core)

- [ ] Migration v9: `meta` key/value table.
- [ ] `AnnotationStore.upsert` bumps `meta['annotationChangeCounter']` in the same
      transaction as the write (including the delete-when-empty path).
- [ ] `public func changeCounter() async throws -> Int` (0 when the row is absent).
- [ ] Test: two writes → counter strictly increases; a no-op read does not change it.

## Task 2 — JSON-RPC plumbing (Core)

- [ ] `JSONValue` enum (null/bool/int/double/string/array/object) with `Codable`, plus
      typed accessors (`.string(_:)`, `.int(_:)`, `.array`, `.object`) used by handlers.
- [ ] `MCPServer`: `handle(line:)` → optional response line (nil for notifications),
      `initialize` / `notifications/initialized` / `tools/list` / `tools/call` / `ping`,
      unknown → `-32601`, malformed → `-32700`.
- [ ] `runStdio()`: read lines from stdin until EOF, write responses to stdout, flush each.
- [ ] Test: `tools/list` shape, unknown method → `-32601`, parse error → `-32700`.

## Task 3 — Read tools (Core)

- [ ] `list_drives`, `browse_folder`, `search`, `get_file`, `list_duplicates`,
      `get_thumbnail` (HEIC → JPEG via ImageIO, MCP `image` content).
- [ ] Mount detection helper: `FileManager.mountedVolumeURLs` + `VolumeMetadata.read`.
- [ ] Every listing paginated (`limit`, `offset`); unknown ids → `isError`, never a throw
      that escapes the dispatcher.
- [ ] Test: `browse_folder` over a seeded tree returns the right subfolders/files with
      annotations attached; bad `volumeId` → `isError`.

## Task 4 — Write tool (Core)

- [ ] `list_annotations` (optional tag filter, paginated).
- [ ] `set_annotations`: batch ≤200, per-item result, maps `tag`/`color` names to
      `Tag`/`FinderColor`, resolves `volumeId` → volumeKey.
- [ ] Test: set → `list_annotations` round-trip; invalid tag name → per-item error, batch
      still succeeds for the rest.

## Task 5 — App wiring

- [ ] `Launcher.main()`: `--mcp` → `MCPServer(catalog:).runStdio()` then exit.
- [ ] `AppEnvironment`: poll `changeCounter` every 2 s; on change bump `dataVersion`.
- [ ] Settings "Agents" tab: the JSON snippet + Copy button + one line of explanation.
- [ ] README section.

## Task 6 — Verify

- [ ] `xcodegen generate`; Core suite green; app builds.
- [ ] Smoke: `printf '…initialize…\n…tools/list…\n' | DiskGallery --mcp` returns valid frames.
- [ ] Extend `MutationGuardTests` with the MCP sources.
