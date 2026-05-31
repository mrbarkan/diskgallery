# Modern Pages Faithful Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-skin the four remaining DiskGallery routes — Duplicates, Action Plan, Transfer Planner, Search — into the Modern bento/glass design from the new Claude Design handoff (chat3), sitting below the now-permanent OLED, matching the mockup's exact tokens and layouts.

**Architecture:** Build new Modern-only page views under `DiskGallery/Views/Modern/`, mirroring how `VolumeBentoWorkspace` already redid the drive browser. Classic views (`DuplicatesView`, `ActionPlanView`, `TransferPlannerView`, `SearchResultsView`, `TaggedListView`) stay **untouched** and continue to serve the Classic skin. A shared `ModernPageScaffold` renders the global topbar + permanent OLED, and a shared `ModernBento` lays out the 1.55fr/1fr × 1.12fr/0.88fr grid the three list pages share. All displayed values bind to real Core data; aspirational actions are wired to the nearest real non-destructive action (tag-as-Delete, pick destination, verify); genuinely-unbacked behaviors are deferred to a future-sprint backlog.

**Tech Stack:** SwiftUI (macOS 15+, Swift 6), DiskGalleryCore services (`duplicates`, `planning`, `annotations`, `search`, `library`), XcodeGen for project regen.

**Source of truth:** `/tmp/dg-design3/disk-gallery/project/diskgallery.css` (exact tokens) and `DiskGallery.html` lines 409–754 (the four new `.page` sections). Chat intent: `/tmp/dg-design3/disk-gallery/chats/chat3.md`.

---

## Data-honesty decisions (confirmed with user)

1. **Action buttons → wire to real actions.** Keep the exact `.cta` look; on click perform the nearest real, non-destructive thing:
   - Duplicates "Delete N duplicates · free X" → fetch the non-kept copies' `Entry`s and `env.applyDecision(.delete, to:)` (tags them; never deletes files).
   - Duplicates "Auto-resolve all" → same keep-rule applied across all loaded sets.
   - Transfer destination → a **real** `Picker` over cataloged drives; projections recompute from it.
   - Resolve-set "Verify" affordance → real `env.verify(set:)` (SHA-256).
2. **Mockup-only data → render in UI now, real function deferred.** These appear faithfully but their deep behavior is in the future-sprint backlog (Task 9):
   - Duplicates file-type filter chips (All/Photos/Video/RAW/Documents) — rendered + selectable; real categorization later.
   - Duplicates "Keep rule" chips (Fastest/Newest/Largest) — rendered; real rule engine later.
   - Action Plan "Run order" steps + "Run plan" CTA — rendered with amounts from real totals; real execution later.
   - Transfer "Start transfer" CTA + time estimate ("2h 40m over USB-C") — rendered; real transfer engine + speed model later.
   - Search "Recent" — rendered as **real in-session** history (fills as you search); persistence later.

---

## Exact shared tokens (from diskgallery.css)

Resolve ink/hair/glass/inset via `DGToken` (scheme-aware). Accent via `env.theme.accent.palette`. Status: `DGToken.ok #4ADE80`, `.warn #F7B955`, `.bad #F8736B`. FinderColor & Tag tints via `.modernColor`.

- **`.filterbar`**: `HStack(spacing:7)`, padding `.horizontal 16`, `.bottom 10`.
- **`.fchip`**: mono 9, tracking 1.0 (0.1em), uppercase, weight .bold, padding H10/V5, radius 8. Off = `DGToken.glass2` bg + `DGToken.ink3` text + clear border. On = `accent.opacity(0.16)` bg + `accent` text + `accent.opacity(0.40)` 1px border.
- **`.cta`**: height 42, radius 12, `LinearGradient(accent→accent2, top→bottom)`, text `palette.ink` (accent-ink), mono 10.5 tracking 1.6 (0.16em) uppercase bold, icon 16, shadow `accent.glow` r? use `.shadow(color: accent.opacity(0.45), radius:10, y:8)`, top inner highlight via overlay. Ghost variant: `DGToken.glass2` bg, `DGToken.ink` text, `DGToken.hair2` 1px border, no shadow.
- **`.sec-h`**: mono 9, tracking 1.8 (0.18em), uppercase, weight .semibold, `DGToken.ink3`.
- **`.cbody`** (side-card scroll body): `ScrollView` with `VStack(alignment:.leading, spacing:14)` padding `.horizontal 16`, `.bottom 16`, `.top 2`.
- **`.fcol`**: `VStack(alignment:.leading, spacing:3)`; `.fname` 13.5 medium `DGToken.ink`; `.fmeta` mono 9 `DGToken.ink3`, lineLimit 1, truncation tail.
- **`.fsize`**: mono 11.5 `DGToken.ink2`, minWidth 66 trailing. `.ok` variant → `DGToken.ok`.
- **`.tile`**: padding 16, glass card. `.big-num`: size 48 weight .heavy, `.u` 21 weight .bold `DGToken.ink2`; reclaim variant num = `accent`. `.tile-reclaim` bg = `accent.opacity(0.12)` gradient over material. `.stack-bar`: height 8, capsule, segments `[accent .46, #5AA2FF .30, ink4 rest]`. `.tile-row`: HStack space-between pinned to bottom (`Spacer(minLength:8)` above). `.tile-sub` 12 `DGToken.ink2`, bold spans `DGToken.ink`.
- **`.plan-rows`/`.plan-row`**: row = `HStack(spacing:11)`; label block width 70 (`RoundedRectangle radius2 8×8 fill tag.modernColor` + label 12 .semibold `ink2`); track height 7 capsule inset bg + colored fill at `share`; amount mono 11 `ink`, minWidth 52 trailing.

---

## File structure

**Create:**
- `DiskGallery/Views/Modern/ModernControls.swift` — shared `CTAButton`, `ModernFilterChip`, `SecHeader`, `ModernNote` (note/warn badge), `ReclaimBigNum`, `StackBar`, `PlanBreakdownRows`.
- `DiskGallery/Views/Modern/ModernBento.swift` — `ModernBento` generic 3-slot layout (topLeft / bottomLeft / right-full-height) + `ModernPageScaffold` (topbar + permanent OLED + content).
- `DiskGallery/Views/Modern/ModernDuplicatesPage.swift` — `ModernDuplicatesPage`, `DupSetRow`, `ResolveSetCard`, `DupReclaimTile`.
- `DiskGallery/Views/Modern/ModernActionPlanPage.swift` — `ModernActionPlanPage`, `PlanItemRow`, `ExecutePlanCard`, `PlanTotalsTile` + `PlanAggregate` helper.
- `DiskGallery/Views/Modern/ModernTransferPage.swift` — `ModernTransferPage`, `TransferQueueCard`, `QueueRow`, `DriveProjectionsCard`, `TransferSummaryTile`.
- `DiskGallery/Views/Modern/ModernSearchPage.swift` — `ModernSearchPage`, `SearchScopeChip`, `RecentRow`.
- `docs/superpowers/plans/future-modern-pages-real-functions.md` — future-sprint backlog (Task 9).

**Modify:**
- `DiskGallery/Views/Modern/ModernWorkspace.swift` — route `.duplicates/.plan/.transfer/.search/.tagged(tag)` to the new pages; delete the old `RouteBentoWorkspace` (superseded by `ModernPageScaffold`).

**Untouched (Classic):** `DuplicatesView.swift`, `ActionPlanView.swift`, `TransferPlannerView.swift`, `SearchResultsView.swift`, `TaggedListView.swift`, `ModernBrowser/Inspector/Sidebar/Topbar/Glass/StatTiles`.

**Verification model:** This app target has no unit tests (only `DiskGalleryCore` does). Per task: `xcodebuild … build` = `** BUILD SUCCEEDED **`. Final: `DiskGalleryCore` test scheme green (48 tests) + user visual check.

---

### Task 1: Shared Modern controls

**Files:**
- Create: `DiskGallery/Views/Modern/ModernControls.swift`

- [ ] **Step 1: Write the controls file**

```swift
import SwiftUI
import DiskGalleryCore

/// The mockup's `.cta` — gradient accent action button (primary) or ghost (secondary).
struct CTAButton: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    let title: String
    var systemImage: String
    var ghost: Bool = false
    var tint: Color? = nil          // override (e.g. bad for Delete)
    let action: () -> Void

    private var accent: Color { tint ?? env.theme.accent.palette.accent }
    private var inkOnAccent: Color { env.theme.accent.palette.ink }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage).font(.system(size: 16, weight: .semibold))
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced)).tracking(1.6)
            }
            .frame(maxWidth: .infinity).frame(height: 42)
            .foregroundStyle(ghost ? DGToken.ink(scheme) : inkOnAccent)
            .background {
                if ghost {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DGToken.glass2(scheme))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DGToken.hair2(scheme), lineWidth: 1))
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [accent, env.theme.accent.palette.accent2], startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.4), lineWidth: 1).blendMode(.overlay))
                }
            }
            .shadow(color: ghost ? .clear : accent.opacity(0.40), radius: 12, y: 8)
        }
        .buttonStyle(.plain)
    }
}

/// The mockup's `.fchip` — mono micro-cap filter chip with selected accent state.
struct ModernFilterChip: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    let label: String
    let selected: Bool
    let action: () -> Void
    private var accent: Color { env.theme.accent.palette.accent }

    var body: some View {
        Button(action: action) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(0.9)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(selected ? accent : DGToken.ink3(scheme))
                .background(selected ? accent.opacity(0.16) : DGToken.glass2(scheme),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? accent.opacity(0.40) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// The mockup's `.sec-h` — mono uppercase section header.
struct SecHeader: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.8)
            .foregroundStyle(DGToken.ink3(scheme))
    }
}

/// The mockup's `.finder-note` — leaf/warn icon + caption. ok (default) or warn tone.
struct ModernNote: View {
    let text: String
    var systemImage: String = "checkmark.shield"
    var warn: Bool = false
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage).font(.system(size: 13))
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(warn ? DGToken.warn : DGToken.ok)
    }
}

/// The mockup's `.stack-bar` — decorative 3-segment capsule (no per-category data exists).
struct StackBar: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Rectangle().fill(env.theme.accent.palette.accent).frame(width: geo.size.width * 0.46)
                Rectangle().fill(Color(hex: 0x5AA2FF)).frame(width: geo.size.width * 0.30)
                Rectangle().fill(DGToken.ink4(scheme))
            }
        }
        .frame(height: 8).clipShape(Capsule())
    }
}

/// The mockup's `.big-num` — 48px headline numeral + small unit. Splits a `Format.bytes` string.
struct BigNum: View {
    @Environment(\.colorScheme) private var scheme
    let bytes: Int64
    var tint: Color
    var body: some View {
        let parts = Format.bytes(bytes).split(separator: " ", maxSplits: 1)
        let value = parts.first.map(String.init) ?? "0"
        let unit = parts.count > 1 ? String(parts[1]) : ""
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(value).font(.system(size: 48, weight: .heavy)).foregroundStyle(tint)
            if !unit.isEmpty { Text(unit).font(.system(size: 21, weight: .bold)).foregroundStyle(DGToken.ink2(scheme)) }
        }
        .lineLimit(1).minimumScaleFactor(0.6)
    }
}

/// The mockup's `.plan-rows` — label · proportional track · amount, one row per tag.
struct PlanBreakdownRows: View {
    @Environment(\.colorScheme) private var scheme
    let rows: [(tag: Tag, bytes: Int64)]
    private var maxBytes: Int64 { max(rows.map(\.bytes).max() ?? 0, 1) }

    var body: some View {
        VStack(spacing: 11) {
            ForEach(rows, id: \.tag) { row in
                HStack(spacing: 11) {
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(row.tag.modernColor).frame(width: 8, height: 8)
                        Text(row.tag.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(DGToken.ink2(scheme))
                    }
                    .frame(width: 70, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DGToken.inset(scheme))
                            Capsule().fill(row.tag.modernColor)
                                .frame(width: geo.size.width * (Double(row.bytes) / Double(maxBytes)))
                        }
                    }
                    .frame(height: 7)
                    Text(Format.bytes(row.bytes)).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DGToken.ink(scheme)).frame(minWidth: 52, alignment: .trailing)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build` (after Task 2 regen). Expected after regen: `** BUILD SUCCEEDED **`. (This task adds no project file yet — built together with Task 2.)

- [ ] **Step 3: Commit** — `feat(modern): shared bento controls (CTA, filter chip, plan rows, big-num)`

---

### Task 2: Bento layout + page scaffold + routing skeleton

**Files:**
- Create: `DiskGallery/Views/Modern/ModernBento.swift`
- Modify: `DiskGallery/Views/Modern/ModernWorkspace.swift`

- [ ] **Step 1: Write `ModernBento.swift`**

```swift
import SwiftUI
import DiskGalleryCore

/// The three list-page bento grid (spec §“page--dupes/plan/transfer”): columns 1.55fr / 1fr,
/// rows 1.12fr / 0.88fr, with the right card spanning both rows.
struct ModernBento<TopLeft: View, BottomLeft: View, Right: View>: View {
    @ViewBuilder var topLeft: TopLeft
    @ViewBuilder var bottomLeft: BottomLeft
    @ViewBuilder var right: Right

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 14
            let leftW = (geo.size.width - gap) * (1.55 / 2.55)
            let rightW = (geo.size.width - gap) - leftW
            let topH = (geo.size.height - gap) * (1.12 / 2.0)
            let botH = (geo.size.height - gap) - topH
            HStack(spacing: gap) {
                VStack(spacing: gap) {
                    topLeft.frame(width: leftW, height: topH)
                    bottomLeft.frame(width: leftW, height: botH)
                }
                right.frame(width: rightW, height: geo.size.height)
            }
        }
    }
}

/// Topbar + permanent OLED + page content. The global toolbar (Display/Check/Re-scan) acts on
/// the currently-selected drive (or the first cataloged one), matching the mockup's global bar.
struct ModernPageScaffold<Content: View>: View {
    @Environment(AppEnvironment.self) private var env
    var leadingIcon: String
    let crumbs: [String]
    @ViewBuilder var content: Content

    private var currentDrive: VolumeSummary? {
        if let key = env.selectedVolumeKey,
           let m = env.volumeSummaries.first(where: { ($0.uuid ?? $0.name) == key }) { return m }
        return env.volumeSummaries.first
    }

    var body: some View {
        VStack(spacing: 14) {
            ModernTopbar(
                leadingIcon: leadingIcon,
                crumbs: crumbs,
                showVolumeActions: currentDrive != nil,
                rescanEnabled: currentDrive.map { env.volumes.isConnected(key: $0.uuid ?? $0.name) } ?? false,
                onDisplay: { withAnimation { env.theme.cycleOLEDLayout() } },
                onChanges: {},
                onRescan: { if let d = currentDrive { env.rescan(volume: d) } },
                onSearch: { env.selection = .search }
            )
            if let d = currentDrive {
                OLEDDisplayView(summary: d, connected: env.volumes.isConnected(key: d.uuid ?? d.name),
                                reclaimable: env.totalReclaimable, layout: env.theme.oledLayout,
                                palette: env.theme.accent.palette)
                    .frame(height: 216)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 2: Rewrite `ModernWorkspace.swift` routing**

Replace the whole `ModernWorkspace` body switch and delete `RouteBentoWorkspace`. Keep `VolumeBentoWorkspace`, `ModernEmptyWorkspace` (and its `currentDrive` helper moves into `ModernPageScaffold`). New router:

```swift
struct ModernWorkspace: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        switch env.selection {
        case .volume(let id):
            if let s = env.volumeSummaries.first(where: { $0.id == id }) {
                VolumeBentoWorkspace(summary: s).id(s.id)
            } else { ModernEmptyWorkspace(title: "Drive not found", systemImage: "externaldrive") }
        case .duplicates:
            ModernDuplicatesPage()
        case .plan:
            ModernActionPlanPage(initialFilter: nil)
        case .tagged(let tag):
            ModernActionPlanPage(initialFilter: tag)
        case .transfer:
            ModernTransferPage()
        case .search:
            ModernSearchPage()
        case nil:
            ModernEmptyWorkspace(title: "Select a drive", systemImage: "sidebar.left",
                                 message: "Pick a drive, or scan a new one, to browse its catalog.")
        }
    }
}
```

- [ ] **Step 3: Add temporary stub pages** so the project compiles before Tasks 3–6 land. At the bottom of `ModernWorkspace.swift`, add minimal stubs that each render `ModernPageScaffold` with a `ModernEmptyWorkspace` body (these get replaced by Tasks 3–6 in their own files; delete the stubs as each real page is created). Example stub:

```swift
// TEMP stub — replaced by ModernDuplicatesPage.swift in Task 3
// (remove when the real file is added)
```

(In practice, create Tasks 3–6 files first in a branch-local order so no stubs are needed; if executing strictly task-by-task, add a one-line `struct ModernDuplicatesPage: View { var body: some View { ModernPageScaffold(leadingIcon: "square.on.square", crumbs: ["Duplicates"]) { ModernEmptyWorkspace(title: "Duplicates") } } }` stub and replace in Task 3.)

- [ ] **Step 4: Regenerate project + build**

```bash
/opt/homebrew/bin/xcodegen generate
xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit** — `feat(modern): bento layout + page scaffold + route the four pages`

---

### Task 3: Duplicates page

**Files:**
- Create: `DiskGallery/Views/Modern/ModernDuplicatesPage.swift`

Layout: `ModernPageScaffold(leadingIcon: "square.on.square", crumbs: ["Duplicates", "All drives"])` wrapping `ModernBento { DupSetsCard } bottomLeft: { DupReclaimTile } right: { ResolveSetCard }`.

- [ ] **Step 1: Write the page.** Key bindings & components:

- **State:** `@State var sets: [DuplicateSet] = []`, `@State var selectedSet: DuplicateSet?`, `@State var filter: String = "All"` (chips All/Photos/Video/RAW/Documents — selection visual only this sprint), `@State var members: [DuplicateMember] = []`.
- **Load sets:** `.task(id: env.dataVersion) { sets = (try? await env.catalog.duplicates.duplicateSets()) ?? []; if selectedSet == nil { selectedSet = sets.first }; await loadMembers() }`.
- **DupSetsCard** (`area-dlist`): `GlassCard` → `ModernCardHeader(systemImage:"square.on.square", title:"Duplicate Sets", meta:"\(Format.count(sets.count)) sets · \(Format.bytes(env.totalReclaimable))", accent:accent)`; filterbar of `ModernFilterChip` for `["All","Photos","Video","RAW","Documents"]`; `List(selection:)` of `DupSetRow` (one per set). Row = `HStack(spacing:12)`: accent square icon (`square.on.square`, size 18, accent), `.fcol` (`fname = set.name`; `fmeta = "\(set.copies) copies · \(set.driveNames)"`), `dup-x` = `"×\(set.copies)"` mono 11 ink2, `.fsize.ok` = `"+\(Format.bytes(set.reclaimable))"` colored `DGToken.ok`. Selecting a row sets `selectedSet` and reloads members.
- **DupReclaimTile** (`area-dstat`): reclaim-tinted `GlassCard`/tile: `SecHeader("Reclaimable across all drives")` (use mono label), `BigNum(bytes: env.totalReclaimable, tint: accent)`, `StackBar`, tile-row: `"\(Format.count(sets.count)) sets · \(Format.count(redundantCopies)) redundant copies"` where `redundantCopies = sets.reduce(0){ $0 + ($1.copies - 1) }`; trailing **`Auto-resolve all`** as an accent mono label button → `autoResolveAll()`.
- **ResolveSetCard** (`area-dside`): `GlassCard` → header `ModernCardHeader("checkmark.circle","Resolve Set", meta:"×\(selectedSet?.copies ?? 0)")` + `.cbody` ScrollView:
  - `dup-hero`: 52×52 thumb (gradient accent.30→bg2, accent `square.on.square` 26) + title `selectedSet?.name` (16 bold) + kind mono: `"\(Format.bytes(selectedSet?.logicalSize ?? 0)) each · +\(Format.bytes(selectedSet?.reclaimable ?? 0)) reclaimable"`.
  - `SecHeader("Copies found")` + copylist: one `CopyRow` per `member` in `members`. Keep rule (this sprint = **keep the first sorted member, mark rest Delete**): index 0 = `.keep` badge + ok-tinted row border/bg; others = `.del` badge. CopyRow grid: `copy-drive = member.volumeName` (12.5 .semibold), `copy-path = member.relPath` (mono 9 ink3, truncation tail), badge trailing.
  - `SecHeader("Keep rule")` + filterbar chips `["Fastest drive","Newest","Largest drive"]` (visual only this sprint).
  - **CTA** `CTAButton(title: "Delete \(max(members.count-1,0)) duplicates · free \(Format.bytes(selectedSet?.reclaimable ?? 0))", systemImage: "trash", tint: DGToken.bad) { await deleteRedundant() }` — fetches non-kept members' `Entry`s and tags them `.delete`.
  - `ModernNote(text: "Verified identical by checksum (SHA-256)", systemImage: "checkmark.shield")`; if any member lacks `contentHash`, instead show a ghost `CTAButton("Verify by checksum","checkmark.shield", ghost:true){ await env.verify(set:selectedSet!) }` (real).
- **Real actions:**
```swift
private func loadMembers() async {
    guard let s = selectedSet else { members = []; return }
    members = (try? await env.catalog.duplicates.members(name: s.name, logicalSize: s.logicalSize)) ?? []
}
private func deleteRedundant() async {
    guard members.count > 1 else { return }
    let redundant = Array(members.dropFirst())          // keep-rule: keep first
    var entries: [Entry] = []
    for m in redundant { if let e = try? await env.catalog.library.entry(id: m.entryId) { entries.append(e) } }
    await env.applyDecision(.delete, to: entries)
}
private func autoResolveAll() async {
    for s in sets {
        let ms = (try? await env.catalog.duplicates.members(name: s.name, logicalSize: s.logicalSize)) ?? []
        guard ms.count > 1 else { continue }
        var entries: [Entry] = []
        for m in ms.dropFirst() { if let e = try? await env.catalog.library.entry(id: m.entryId) { entries.append(e) } }
        await env.applyDecision(.delete, to: entries)
    }
}
```

- [ ] **Step 2: Delete the Task-2 stub** for `ModernDuplicatesPage`; build (`xcodegen generate` only needed if a NEW file — yes, run it). Expected `** BUILD SUCCEEDED **`.
- [ ] **Step 3: Visual checkpoint** — user confirms Duplicates page matches mockup.
- [ ] **Step 4: Commit** — `feat(modern): Duplicates bento page (sets · resolve · reclaim) with real tag-as-delete`

---

### Task 4: Action Plan page

**Files:**
- Create: `DiskGallery/Views/Modern/ModernActionPlanPage.swift`

Layout: `ModernPageScaffold(leadingIcon:"checklist", crumbs:["Action Plan", "\(plannedCount) tagged"])` → `ModernBento { TaggedItemsCard } bottomLeft: { PlanTotalsTile } right: { ExecutePlanCard }`. Takes `let initialFilter: Tag?` (nil = "All"; from `.tagged(tag)` route preselect that tag).

- [ ] **Step 1: Aggregate helper + page.**

- **`PlanAggregate`** (private struct built from `[DriveStats]`):
```swift
private struct PlanAggregate {
    var bytes: [Tag: Int64] = [:]; var counts: [Tag: Int] = [:]; var disconnected = 0
    init(_ stats: [DriveStats], isConnected: (String) -> Bool) {
        for s in stats {
            for t in Tag.actionTags { bytes[t, default: 0] += s.bytes(for: t); counts[t, default: 0] += s.count(for: t) }
            if s.hasPending && !isConnected(s.volumeKey) { disconnected += 1 }
        }
    }
    var totalCount: Int { Tag.actionTags.reduce(0) { $0 + (counts[$1] ?? 0) } }
    var totalBytes: Int64 { Tag.actionTags.reduce(0) { $0 + (bytes[$1] ?? 0) } }
}
```
- **State:** `@State var items: [TaggedEntry] = []`, `@State var agg = PlanAggregate([], isConnected: {_ in false})`, `@State var filter: Tag?`. Init sets `_filter = State(initialValue: initialFilter)`.
- **Load:** `.task(id: env.dataVersion) { let stats = (try? await env.catalog.planning.driveStats()) ?? []; agg = PlanAggregate(stats){ env.volumes.isConnected(key:$0) }; await loadItems() }`. `loadItems`: union `taggedEntries(t)` over `filter.map{[$0]} ?? Tag.actionTags`, sorted by `displaySize` desc.
- **TaggedItemsCard** (`area-plist`): header `("list.bullet.rectangle","Tagged Items", meta:"\(agg.totalCount) items · \(Format.bytes(agg.totalBytes))")`; filterbar `ModernFilterChip` for `["All"]+Tag.actionTags.label`, selected when matches `filter`; `List` of `PlanItemRow`. Row: icon (`folder.fill` if `isDir==true` accent else `doc` ink3), `.fcol` (`displayName`; `fmeta = "\(volumeName ?? "—") · \(parentPath(relPath))"`), `ChipView(tag: item.tag)`, `.fsize` `Format.bytes(displaySize ?? 0)`.
- **PlanTotalsTile** (`area-ptot`): `GlassCard` tile with mono label `"Plan Totals"` + `PlanBreakdownRows(rows: [(.keep,…),(.backup,…),(.move,…),(.review,…),(.delete,…)] from agg.bytes)`.
- **ExecutePlanCard** (`area-pexec`): header `("checkmark.circle","Execute Plan", meta:"\(agg.totalCount) tagged")` + `.cbody`:
  - `sum-grid` 2×2 of `SumCell`: Delete=`bytes[.delete]` (tint bad, "Freed by delete"), Backup=`counts[.backup]` (blue, "To back up"), Move=`counts[.move]` (purple, "To move"), Review=`counts[.review]` (warn, "Need review"). `SumCell`: glass2 radius12 padding 12/13; value 22 .heavy tinted + small unit; `SecHeader`-style caption ink3.
  - `SecHeader("Run order")` + step-list (4 `StepRow`): `1 Verify checksums · \(agg.totalCount) items`, `2 Move flagged files · \(Format.bytes(bytes[.move]))`, `3 Back up · \(Format.bytes(bytes[.backup]))`, `4 Delete confirmed duplicates · \(Format.bytes(bytes[.delete]))`. `StepRow`: 20×20 accent-soft circle w/ mono number + label 12.5 ink2 + amt mono 11 ink trailing; hairline divider between.
  - **CTA** `CTAButton("Run plan","play.fill"){ /* future-sprint execution; no-op this sprint */ }` (rendered; real execution in backlog).
  - `ModernNote(text:"\(agg.disconnected) drives must be connected to run", systemImage:"exclamationmark.triangle", warn:true)`.

- [ ] **Step 2: Build** (`xcodegen generate` + build). Expected `** BUILD SUCCEEDED **`.
- [ ] **Step 3: Visual checkpoint.**
- [ ] **Step 4: Commit** — `feat(modern): Action Plan bento page (tagged items · execute · totals)`

---

### Task 5: Transfer Planner page

**Files:**
- Create: `DiskGallery/Views/Modern/ModernTransferPage.swift`

Layout: `ModernPageScaffold(leadingIcon:"arrow.left.arrow.right", crumbs:["Transfer Planner", "\(queue.count) queued"])` → `ModernBento { TransferQueueCard } bottomLeft: { TransferSummaryTile } right: { DriveProjectionsCard }`.

- [ ] **Step 1: Page with real destination picker + projections.**

- **Queue = real Move + Backup tagged items.** State: `@State var queue: [TaggedEntry] = []`, `@State var stats: [DriveStats] = []`, `@State var destinationKey: String?` (the real picker selection). Load: `taggedEntries(.move)+taggedEntries(.backup)` + `driveStats()`. `queueBytes = queue.compactMap(\.displaySize).reduce(0,+)`.
- **TransferQueueCard** (`area-tqueue`): header `("arrow.left.arrow.right","Transfer Queue", meta:"\(queue.count) queued · \(Format.bytes(queueBytes))")`; List of `QueueRow`. Row grid 22/1fr/auto: ficon accent (folder/doc), `.fcol` (`fname=displayName`; `qpath` = `HStack` `volumeName` → `arrow.right` (accent 13) → `destName`), trailing `VStack(align:.trailing,spacing:6)` of `.fsize` + `QStatus` (`.ready` if source drive connected else `.queued` "Waiting drive"). `destName` = chosen destination's name or "—".
- **DriveProjectionsCard** (`area-tproj`): header `("externaldrive","Drive Projections", meta:"after transfer")` + `.cbody`:
  - **Destination `Picker`** (real, `.menu` style) over `stats` names → sets `destinationKey`.
  - For each drive in `stats` with capacity: `ProjRow`. Current used fraction `cur = 1 - free/total` (or `usedLogical/total`). Incoming/outgoing: if drive == destination, `inc = movedInBytes/total` (sum of queue sizes) → bar `cur` (ink4) + `inc` (accent gradient), delta `cur% → (cur+inc)%`; if drive is a source (holds queued items), `inc` shrinks → show projected lower %; over-capacity portion → `over` (bad) when `cur+inc > 1`. Delta text colored: accent normally, `DGToken.bad` if projected > 0.95, `DGToken.ok` if it drops.
  - `ModernNote(warn:true)` when destination projected > 0.95: `"\(destName) will exceed 95% — pick another target"`.
- **TransferSummaryTile** (`area-tsum`): mono label "Transfer Summary"; `BigNum(bytes: queueBytes, tint: env...accent)`; tile-sub `"\(queue.count) jobs · est. — over USB-C"` (time estimate rendered per mockup but value is `—` this sprint; real model in backlog); **CTA** `CTAButton("Start transfer","arrow.left.arrow.right"){ /* future-sprint; no-op */ }`.
- `ProjRow`/`QStatus` styling per tokens above (proj-bar height 12 radius6; qstatus mono 9 uppercase).

- [ ] **Step 2: Build.** Expected `** BUILD SUCCEEDED **`.
- [ ] **Step 3: Visual checkpoint.**
- [ ] **Step 4: Commit** — `feat(modern): Transfer Planner bento page (queue · real projections · summary)`

---

### Task 6: Search page

**Files:**
- Create: `DiskGallery/Views/Modern/ModernSearchPage.swift`

Layout: `ModernPageScaffold(leadingIcon:"magnifyingglass", crumbs:["Search"])` → content = the hero centered when no query, results list when querying.

- [ ] **Step 1: Page with live search + in-session recent.**

- **State:** `@State var query = ""`, `@State var results: [SearchResult] = []`, `@State var scope: SearchScope = .all`, `@State var scopeLabel = "All drives"`, `@State var recent: [String] = []` (in-session). `@FocusState var focused`.
- **Hero card** (`search-hero`, width `min(580, 92%)`, centered via `.frame(maxWidth:.infinity, maxHeight:.infinity)` + center alignment): title row (accent magnifier 18 + "Search all drives" 13 bold) + sub mono "Catalog stays searchable even when drives are offline"; **`search-big`**: height 58 radius16 glass2 + hair2, accent magnifier 22, `TextField("Filenames, paths, Finder tags…", text:$query)` 18pt, `⌘K` kbd; `search-scopes`: `SearchScopeChip` for "All drives" + each `env.volumeSummaries.name` (sets `scope`); **Recent**: `SecHeader("Recent")` + `RecentRow` per `recent` (clock icon + text + run on tap). Empty recent → hide section or show muted "No recent searches yet."
- **Live results:** `.task(id: query+scopeLabel) { guard query.count >= 2 else { results = []; return }; results = (try? await env.catalog.search.search(query, scope: scope)) ?? []; rememberRecent(query) }`. When `!results.isEmpty || query.count>=2`, render a `GlassCard` results list (reuse `.frow` look: icon, name, volume meta, mono size) instead of/above the hero. `rememberRecent`: dedupe + cap 5.
- Scope chip selection updates `scope`: "All drives" → `.all`; a volume → `.volumeLatest(volume.latestSnapshotId!)` (guard non-nil; else `.all`).

- [ ] **Step 2: Build.** Expected `** BUILD SUCCEEDED **`.
- [ ] **Step 3: Visual checkpoint.**
- [ ] **Step 4: Commit** — `feat(modern): Search bento page (hero · scopes · live results · in-session recent)`

---

### Task 7: Routing cleanup + full verification

**Files:**
- Modify: `DiskGallery/Views/Modern/ModernWorkspace.swift` (remove any leftover stubs)

- [ ] **Step 1:** Confirm `RouteBentoWorkspace` is fully removed and all four routes point at the real pages; `.tagged(tag)` → `ModernActionPlanPage(initialFilter: tag)`.
- [ ] **Step 2: Regenerate + build app.**
```bash
/opt/homebrew/bin/xcodegen generate
xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build
```
Expected `** BUILD SUCCEEDED **`.
- [ ] **Step 3: Run Core tests** (must stay green; we changed no Core code).
```bash
xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS,arch=arm64' test
```
Expected: 48 tests, 0 failures.
- [ ] **Step 4: Commit** — `chore(modern): finalize page routing`

---

### Task 8: Classic regression sanity

- [ ] **Step 1:** Toggle to Classic in a manual run (user) — confirm `DuplicatesView`, `ActionPlanView`, `TransferPlannerView`, search, tagged lists all still render via the untouched Classic path (they were never modified). No build step (covered by Task 7).
- [ ] **Step 2:** If user reports any Classic regression, investigate; otherwise no-op.

---

### Task 9: Future-sprint backlog

**Files:**
- Create: `docs/superpowers/plans/future-modern-pages-real-functions.md`

- [ ] **Step 1:** Write the backlog documenting the deferred "make it real" work the user requested, with concrete approaches:
  1. **Duplicates file-type filter** — categorize sets by extension groups (RAW: cr2/cr3/nef/arw/dng/raf; Photos: jpg/jpeg/png/heic/tiff; Video: mov/mp4/m4v/avi/mkv; Documents: pdf/doc/docx/txt/md/key/pages). Add `category` to `DuplicateSet` or filter client-side on `name` extension.
  2. **Duplicates keep-rule engine** — implement Fastest/Newest/Largest-drive selection of which copy to keep (needs drive speed metadata for "fastest"; "newest" from `member.modifiedAt`; "largest drive" from `DriveStats.totalCapacity`). Drive the keep/delete badges from the chosen rule.
  3. **Action Plan execution** — wire "Run plan" to write Finder color tags to connected drives via `Catalog.finderTags` (`FinderTagWriter`) + perform user-confirmed moves/backups via a new `TransferService`. Sequenced per the "Run order" steps with progress.
  4. **Transfer engine + estimate** — real file copy/move with progress; time estimate from a measured/throughput model (USB-C/Thunderbolt) × bytes. Persist a real transfer queue.
  5. **Search recent persistence** — store recent queries in `UserDefaults` (or a small Core table); seed scopes like "Tagged: Delete" / "Duplicates only" as real saved searches.
- [ ] **Step 2: Commit** — `docs: future-sprint backlog for Modern pages real functions`

---

## Self-Review

- **Spec coverage:** Duplicates (dlist/dside/dstat) → Task 3; Action Plan (plist/pexec/ptot) → Task 4; Transfer (tqueue/tproj/tsum) → Task 5; Search (search-hero) → Task 6; permanent OLED + global topbar on every page → `ModernPageScaffold` (Task 2); nav Action-Tag chips → `.tagged` route preselect filter (Tasks 2+4). ✓
- **Type consistency:** `ModernPageScaffold`, `ModernBento`, `CTAButton`, `ModernFilterChip`, `SecHeader`, `ModernNote`, `StackBar`, `BigNum`, `PlanBreakdownRows`, `PlanAggregate` names used consistently across tasks. Real APIs verified against the data map: `duplicates.duplicateSets()/members(name:logicalSize:)/totalReclaimable()`, `library.entry(id:)`, `planning.driveStats()`, `annotations.taggedEntries(_:)`, `search.search(_:scope:)`, `env.applyDecision(_:to:)`, `env.verify(set:)`, `env.volumes.isConnected(key:)`. ✓
- **Data honesty:** every displayed number traces to a real field; mockup-only elements are rendered but their real behavior is in Task 9's backlog per the user's instruction. ✓
- **No Classic regression risk:** zero Classic files modified; only `ModernWorkspace.swift` routing changes. ✓
