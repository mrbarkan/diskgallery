# DiskGallery — Licensing & Beta Hard-Stop Design

**Date:** 2026-06-01
**Status:** Approved (brainstorm)
**Goal:** Make the direct (Developer ID) build sellable: a perpetual free tier + a
one-time **Pro** unlock, gated through the existing offline Ed25519 license system,
plus a build-specific **beta hard-stop** so unlocked pre-release copies don't circulate.

---

## Decisions (locked during brainstorm)

| Topic | Decision |
|-------|----------|
| Monetization model | **Freemium** — perpetual free tier + one-time Pro unlock. No trial. |
| Feature split | **Catalog free, power-tools Pro.** |
| Locked UX | Pro controls stay **visible with a "PRO" badge**; tap → shared **upgrade sheet**. |
| Beta stop | Build-specific **14-day hard stop**, **14 days from first launch**. |
| Beta expiry screen | **Full-window block** with **Check-for-update** + **Send-feedback** buttons. |
| Pro price | **$19** one-time (placeholder in `LicenseConfig`, change anytime). |
| Key issuer | **SPM executable in repo** (`Tools/dgkeygen`), private key via env var. |

### Free vs. Pro feature split

**Free (the read-only catalog — the product's identity):**
- Scan / index drives
- Browse volumes & entries
- Search with typed queries
- View duplicate sets
- Manual per-file tagging (decisions + Finder colors)
- Themes / appearance

**Pro (the power-tools — bulk & automation):**
- Saved-search scopes (`Feature.savedSearches`)
- Duplicate keep-rule auto-marking (`Feature.keepRuleApply`)
- Bulk Finder-tag sync — Action Plan "Run plan" (`Feature.bulkTagSync`)
- Duplicates file-type filter chips (`Feature.dupFilterChips`)
- Export / Import Library (`Feature.exportImport`)
- Transfer engine — future (`Feature.transfer`)

> Typed search stays free; **saved-search scopes** (the standalone predicate chips) are Pro.
> Viewing duplicate sets is free; the **filter chips** and **keep-rule auto-mark** are Pro.

---

## Architecture

Two independent gates feed behavior; `LicenseStore` remains the single source of truth.

1. **License gate (freemium):** `LicenseStore.isPro`. True when `.licensed`, or when
   `.unconfigured` (dev builds with no embedded public key stay fully unlocked).
   The previous `.trial` / `.trialExpired` states are **removed**.

2. **Beta gate (build-specific):** a compile-time `BETA` flag. When defined, `BetaGate`
   records first-launch date and computes `isExpired` (first-launch + 14 days). Inert
   (`isExpired == false`) in non-beta builds.

**Resolution order:**
- At launch, **beta expiry is checked first** — if expired, the whole app is replaced by
  `BetaExpiredView` and the catalog is never opened.
- Within a running app, `isPro` gates individual Pro actions via
  `LicenseStore.isUnlocked(_ feature: Feature) -> Bool`.

A `Feature` enum gives each gated control a stable identity. `isUnlocked` returns `isPro`
today; the enum lets the policy vary per-feature later without touching call sites.

---

## Components & Files

### Core (`DiskGalleryCore/`) — pure, testable
- `Licensing/LicenseVerifier.swift` — **exists, unchanged** (`LicenseVerifier`,
  `LicenseSigner`, `LicensePayload`, `LicenseError`).
- `Licensing/Feature.swift` *(new)*:
  ```swift
  public enum Feature: String, CaseIterable, Sendable {
      case savedSearches, keepRuleApply, bulkTagSync, dupFilterChips, exportImport, transfer
      public var displayName: String { … }   // human label for the upgrade sheet
  }
  ```

### App (`DiskGallery/App/`)
- `LicenseStore.swift` *(modified)*:
  - `Status` becomes `.unconfigured / .free / .licensed(email:)` (drop trial states).
  - `var isPro: Bool` — true for `.unconfigured` and `.licensed`; false for `.free`.
  - `func isUnlocked(_ feature: Feature) -> Bool { isPro }`.
  - Embed the real `publicKeyBase64`.
  - `refresh()` no longer computes trial days; `.free` is the default when configured and
    no valid key is stored.
  - Optional injectable clock for tests.
- `BetaGate.swift` *(new)* — `@MainActor @Observable`:
  - `#if BETA`: read/write first-launch `Date` in UserDefaults (`beta.firstLaunch`),
    expose `expiryDate` (first-launch + 14d), `daysLeft`, `isExpired` (`now >= expiryDate`).
  - non-beta: inert, `isExpired == false`.
  - Injectable `now` + first-launch for tests.
- `LicenseConfig` (in `LicenseStore.swift`) *(modified)*:
  - Fill `publicKeyBase64`.
  - Add `proPrice = "$19"`, `feedbackURL`, `updatesURL`. Keep `product`, `buyURL`.
  - Remove `trialDays`.

### App (`DiskGallery/Views/`)
- `Upgrade/UpgradeSheet.swift` *(new)* — shared "Unlock DiskGallery Pro" sheet: price,
  Pro feature bullets, **Buy** button (opens `buyURL`), and a paste-key field calling
  `license.activate`. Dismisses & unlocks on success.
- `Upgrade/ProBadge.swift` *(new)* — small "PRO" lock chip, plus a
  `.proGated(_ feature: Feature)` view modifier: overlays the badge and intercepts taps
  to present `UpgradeSheet` when `!license.isUnlocked(feature)`; passes through when unlocked.
- `Brand/BetaExpiredView.swift` *(new)* — full-window block: "This beta has expired,"
  **Check for update** (opens `updatesURL`; Sparkle-ready later) and **Send feedback**
  (opens `feedbackURL`).
- `SettingsView.swift` (`LicenseSettings`) *(modified)* — reflect the new 3-state status
  (Free / Pro / unconfigured).
- `App/DiskGalleryApp.swift` *(modified)* — at the root, when `betaGate.isExpired`, render
  `BetaExpiredView` instead of `ContentView`. Hold a `BetaGate` alongside `AppEnvironment`.
- Modern pages *(modified)* — wrap Pro controls with `.proGated(...)`:
  - `ModernSearchPage.swift` → saved-search chips (`.savedSearches`)
  - `ModernDuplicatesPage.swift` → filter chips (`.dupFilterChips`), keep-rule apply (`.keepRuleApply`)
  - `ModernActionPlanPage.swift` → "Run plan" (`.bulkTagSync`)
  - Export/Import menu commands → (`.exportImport`)

### Tools (`Tools/dgkeygen/`) *(new)* — seller-side SPM executable
- `swift run dgkeygen --generate-keypair` → prints a fresh Ed25519 keypair (one-time).
- `DG_PRIVATE_KEY=<base64> swift run dgkeygen --email buyer@x.com [--seats N] [--expires …]`
  → prints a signed license key.
- Private key read from `DG_PRIVATE_KEY` env var — **never committed**, never in the app.
- Depends on `DiskGalleryCore`'s `LicenseSigner` (reuse, no crypto duplication).

---

## Data Flow

**First launch (beta build):** `BetaGate` writes `now` as first-launch; `expiryDate = now + 14d`.

**Launch gate (`DiskGalleryApp`):**
```
if betaGate.isExpired  → BetaExpiredView   (catalog never opened)
else                   → ContentView       (normal app)
```

**Pro action tap (free user):** `.proGated(.bulkTagSync)` checks
`license.isUnlocked(.bulkTagSync)`. Unlocked → action runs. Locked → tap intercepted,
`UpgradeSheet` presented, no Pro work executes.

**Activation:** paste key (sheet or Settings) → `license.activate(key)` →
`LicenseVerifier.verify` (offline Ed25519) → on success `status = .licensed(email)`,
persisted; all `proGated` controls go live immediately (observable). Deactivate → `.free`.

**Key issuance (off-device):** sale → `DG_PRIVATE_KEY=… swift run dgkeygen --email …` →
signed key delivered to buyer. Private key never touches app or repo.

---

## Error Handling
- **Bad / expired / wrong-product key:** `activate` returns the existing `LicenseError`
  message, shown inline (already implemented).
- **Empty `publicKeyBase64`:** `LicenseVerifier` init throws `.notConfigured` →
  `status = .unconfigured` → `isPro = true`. Safety net: a misconfigured build never locks
  everyone out.
- **Corrupt / missing first-launch date:** treat as "first launch now" (fail-open —
  never falsely expire on day one).
- **Clock roll-back:** out of scope (acceptable for an indie utility / beta).

---

## Testing
- **Core (`DiskGalleryCoreTests`, XCTest):**
  - `Feature` rawValue ↔ case round-trip; every case has a non-empty `displayName`.
  - `LicenseSigner` → `LicenseVerifier` happy path (exists); add tampered-signature and
    wrong-product negative tests if not already present.
- **App-level logic:**
  - `LicenseStore.isUnlocked` → false when `.free`; true when `.licensed` and `.unconfigured`.
  - `BetaGate` expiry math via injected `now` + first-launch: not expired at day 0,
    expired at day 15. Requires injectable clock.
- **Manual smoke:**
  - Build with a known-good key: free → activate → Pro → deactivate → free.
  - `BETA` build with a backdated first-launch date → `BetaExpiredView` appears.

---

## Out of Scope (future)
- Mac App Store / StoreKit IAP channel (separate `MAS` build flag, App Sandbox +
  security-scoped bookmarks). This spec covers the **direct** channel only.
- Sparkle auto-update wiring ("Check for update" opens `updatesURL` for now).
- Real Transfer engine (`Feature.transfer` reserved; page still "coming soon").
- Per-feature differentiated unlock policy (enum is ready; policy stays uniform = `isPro`).
