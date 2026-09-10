# DiskGallery — MCP server: let AI agents read the catalog and propose an organization

**Date:** 2026-09-09
**Status:** Draft design — awaiting review before the implementation plan

## Background & motivation

DiskGallery already holds everything an agent needs to reason about a media
library: the offline catalog (every drive's tree, sizes, dates, extensions),
the thumbnail sidecar cache, duplicate sets, and the user's own decisions
(Keep / Delete / Review / Move / Backup tags, Finder colors, notes). What is
missing is a way for an external AI agent (Claude Desktop, Claude Code, any
Model Context Protocol client) to *see* that data and *propose* something back.

The key observation: **the annotation model is already the proposal channel.**
An agent that tags files and folders is proposing an organization the user then
reviews in the existing Tagged lists and Organize view. The planner turns tags
into a plan; execution stays behind the existing copy → verify → delete gates.
So this feature adds a read surface plus one write tool, and nothing on the
"act" side.

## Decisions

1. **Transport:** MCP over stdio, served by the app binary itself as a new
   launcher mode: `DiskGallery.app/Contents/MacOS/DiskGallery --mcp`. Mirrors
   the existing `--scan` headless branch in `Launcher.main()`. No HTTP, no
   daemon, no new process to manage — the MCP client spawns it.
2. **No new dependency.** MCP is JSON-RPC 2.0 over newline-delimited stdin/
   stdout. Hand-rolled with `Codable` in a small `MCP/` folder of the app
   target (it is a shell concern, like the SwiftUI views; Core stays
   protocol-agnostic).
3. **Read-only, plus annotations.** The only mutation is writing annotations to
   the catalog DB. The server never touches a drive and never triggers the
   execution engine. `MutationGuardTests`-style static checks apply to the new
   files (see Testing).
4. **Same catalog, shared with the running app.** The server opens
   `Catalog.makeDefault()`. GRDB's WAL `DatabasePool` supports a second process
   reading and writing concurrently. The app learns about external annotation
   writes through a lightweight "catalog changed on disk" signal (below).
5. **Folder-by-folder, paginated.** Large drives cannot be handed to an agent
   whole. Every listing tool takes `limit`/`offset` and the browse tool returns
   one folder level (reusing the Gallery's direct-children + subfolder queries).
6. **Free feature, same as the Gallery.** Browsing and tagging are free today;
   an agent doing the same is not gated.

## Architecture

```
MCP client (Claude Desktop / Claude Code / …)
        │ stdio, JSON-RPC 2.0
        ▼
DiskGallery --mcp        DiskGallery/MCP/
  MCPServer              ── read loop, dispatch, JSON-RPC envelope
  MCPTools               ── tool schemas + handlers, each a thin call into Catalog
        │
        ▼
DiskGalleryCore.Catalog (library, gallery, search, duplicates, annotations, thumbnails)
        │
        ▼
~/Library/Application Support/DiskGallery/{catalog.sqlite, thumbnails/}
```

### Protocol surface (minimum)

- `initialize` → server info + `capabilities.tools`.
- `notifications/initialized` → ignored.
- `tools/list` → the tool table below.
- `tools/call` → dispatch; errors return `isError: true` with a plain message.
- `ping` → `{}`.
- Anything else → JSON-RPC `-32601` method not found.

Protocol version string is echoed from the client's `initialize` request when it
is one we recognise, else the newest we implement. Text content only, except
`get_thumbnail` which returns MCP `image` content.

### Tools

| Tool | Args | Returns | Backing call |
|---|---|---|---|
| `list_drives` | — | drives: id, name, uuid, connected, fileCount, capacity, lastScanned, previewTypes | `library.volumes()` + `NSWorkspace` mount check |
| `browse_folder` | `volumeId`, `relPath` ("" = root), `limit`, `offset`, `hideHidden` | subfolders (name, relPath, mediaCount) + files (name, relPath, ext, size, modifiedAt, tag, color, note, hasThumbnail) | `gallery.folders(...)`, `gallery.items(directOnly: true)` for media, `library.children` for non-media, `annotations.annotations(volumeKey:relPaths:)`, `thumbnails.cachedRelPaths` |
| `search` | `query`, `limit`, `hideHidden` | matches with drive provenance | `search.search(_:limit:hideHidden:)` |
| `get_file` | `volumeId`, `relPath` | full entry + annotation + duplicate copies (name+size key) | `library.entry`, `annotations.annotation`, `duplicates.members(name:logicalSize:)` |
| `list_duplicates` | `minCopies`, `limit`, `crossDriveOnly` | duplicate sets with members | `duplicates.duplicateSets(...)` + `members` |
| `get_thumbnail` | `volumeId`, `relPath`, `maxPixel` (≤512) | MCP image content (JPEG) or an `isError` "no cached preview" | `thumbnails.thumbnailURL` → HEIC decoded with ImageIO, re-encoded JPEG |
| `list_annotations` | `tag?`, `limit`, `offset` | the user's/agent's current decisions | `annotations.taggedEntries(in:)` / `all()` |
| `set_annotations` | `items: [{volumeId, relPath, tag?, color?, note?}]` (≤200 per call) | per-item ok/error | `annotations.set(tag:color:note:volumeKey:relPath:)` |

`browse_folder` is the workhorse: one call per folder gives an agent the names,
sizes, dates, existing decisions, and which files it can look at. The agent
drills the tree the same way the Gallery now does.

Tag and color values are the `Tag` / `FinderColor` raw names (`keep`, `delete`,
`review`, `move`, `backup`, `none`; `gray`…`purple`). Notes are free text and
are the natural place for an agent to explain *why* ("duplicate of
2024/trip/b.jpg on Backup A", "looks like a screenshot").

### Proposal convention

There is no separate "proposal" object. An agent proposes by tagging:

- `review` + note → "look at this".
- `delete` + note → "safe to remove because …".
- `move` / `backup` + note → "belongs on drive X".
- Finder colors → grouping the agent wants to suggest (e.g. green = a shoot).

The user reviews in the app exactly as they review their own tags, changes what
they disagree with, and runs Organize. Nothing an agent writes can move or
delete a byte on a drive.

### Refresh signal (app side)

The app's views reload on `AppEnvironment.dataVersion`, which only bumps on
in-app mutations. To notice MCP writes:

- The server bumps a small integer in a new `meta` row (`externalWriteCounter`)
  inside the same transaction as each annotation write (Core migration, one
  column-free key/value row).
- The app polls that counter every 2 s while it has focus (a `Timer` in
  `AppEnvironment`, reading one row); when it changes, `dataVersion += 1`.

Polling one row every two seconds is negligible and avoids file-watcher
complexity. `ponytail:` upgrade to `DispatchSource` file monitoring only if
the poll ever shows up in profiling.

### Connecting a client

Documented in `README` with a copy-paste Claude Desktop / Claude Code config:

```json
{ "mcpServers": { "diskgallery": {
    "command": "/Applications/DiskGallery.app/Contents/MacOS/DiskGallery",
    "args": ["--mcp"] } } }
```

Settings gets a small "AI Agents" section that shows this snippet with a Copy
button. No in-app chat, no API keys.

## Error handling

- Catalog missing / unreadable → `initialize` succeeds, every tool returns
  `isError` with "Catalog not found — open DiskGallery and scan a drive first".
- Unknown `volumeId` / `relPath` → `isError`, no exception escapes.
- Thumbnail missing → `isError` with a hint to generate previews in the app.
- `set_annotations` is per-item: one bad path does not fail the batch; each
  item reports its own result.
- Malformed JSON line → JSON-RPC parse error, loop continues.
- Stdout is reserved for protocol frames; all logging goes to stderr.

## Testing

- **Core:** `meta` counter migration + bump-on-annotation-write test.
- **App target (new `DiskGalleryMCPTests`, or tests in Core if the dispatcher
  is moved there — decided at plan time):** the JSON-RPC dispatcher is tested
  with an in-memory `Catalog` (the `Fixture` in `DiskGalleryCoreTests/
  Support.swift` pattern): `tools/list` shape, `browse_folder` on a seeded
  tree, `set_annotations` round-trip visible through `list_annotations`,
  unknown method → `-32601`, thumbnail miss → `isError`.
- **Read-only guard:** extend `MutationGuardTests` to grep `DiskGallery/MCP/`
  for filesystem mutation APIs.
- **Smoke:** `echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | DiskGallery --mcp`
  and a Claude Code session with the server configured, browsing one drive.

## Staged delivery

- **Stage A — server + read tools.** `--mcp` mode, JSON-RPC loop,
  `list_drives`, `browse_folder`, `search`, `get_file`, `list_duplicates`,
  `get_thumbnail`. Verifiable end to end with Claude Code.
- **Stage B — annotations + refresh.** `list_annotations`, `set_annotations`,
  the `meta` counter, app-side poll, Settings snippet, README.

## Non-goals

- No execution, plan approval, rename, or any drive write from an agent.
- No in-app chat or bundled model; agents live outside the app.
- No remote/HTTP transport; stdio only (a client on the same Mac).
- No full-resolution image access; thumbnails only (≤512 px).
- No scan triggering from MCP in v1 (can be added as a tool later; it is a
  read-only operation but long-running and needs a connected drive).

## Risks

- **Concurrent DB access** while the app is open: WAL handles it; both sides
  already use GRDB's busy timeout. Verified in the smoke test with the app
  running.
- **Agent tag spam:** `set_annotations` is capped per call and every write is
  visible and reversible in the Tagged lists. A future "clear agent tags" action
  can key off a `source` column if it proves needed — not built now.
- **Token cost for agents:** thumbnails are JPEG at ≤512 px and only on
  request; listings are paginated.
