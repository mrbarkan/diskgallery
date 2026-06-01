# Licensing & Beta Hard-Stop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the direct build sellable — perpetual free tier + one-time **Pro** unlock via the existing offline Ed25519 license system, plus a build-specific 14-day beta hard-stop.

**Architecture:** Testable logic (the `Feature` enum, beta-expiry date math) lives in `DiskGalleryCore` as pure units with XCTest coverage. SwiftUI stores (`LicenseStore`, `BetaGate`) are thin `@MainActor @Observable` wrappers verified by build. A `.proGated(_:)` view modifier shows a PRO badge and routes taps to one shared `UpgradeSheet`. A compile-time `BETA` flag activates the hard-stop and shows `BetaExpiredView` at the app root.

**Tech Stack:** Swift 6, SwiftUI (macOS 15), CryptoKit (Ed25519, already in `LicenseVerifier`), XCTest, XcodeGen, SwiftPM (for the `dgkeygen` tool).

**Reference spec:** `docs/superpowers/specs/2026-06-01-licensing-and-beta-gate-design.md`

**Conventions:**
- Core tests run with: `xcodebuild test -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS' -only-testing:DiskGalleryCoreTests/<Class>` (omit `-only-testing` to run all).
- App builds with: `xcodebuild build -project DiskGallery.xcodeproj -scheme DiskGallery -destination 'platform=macOS'`.
- After adding/removing **files**, regenerate the project first: `xcodegen generate`.
- Branch: create `feat/licensing-and-beta-gate` off `main` before Task 1.

---

## File Structure

**Core (new):**
- `DiskGalleryCore/Licensing/Feature.swift` — `Feature` enum: stable identity + display name per gated capability.
- `DiskGalleryCore/Licensing/BetaWindow.swift` — pure beta-expiry date math (testable, no UI/UserDefaults).

**Core (existing, unchanged):**
- `DiskGalleryCore/Licensing/LicenseVerifier.swift` — `LicenseVerifier`, `LicenseSigner`, `LicensePayload`, `LicenseError`.

**App (new):**
- `DiskGallery/App/BetaGate.swift` — `@Observable` wrapper: persists first-launch, exposes `isExpired`/`daysLeft` via `BetaWindow` under `#if BETA`.
- `DiskGallery/Views/Upgrade/UpgradeSheet.swift` — shared "Unlock DiskGallery Pro" sheet.
- `DiskGallery/Views/Upgrade/ProBadge.swift` — PRO chip + `.proGated(_:)` modifier.
- `DiskGallery/Views/Brand/BetaExpiredView.swift` — full-window expiry block.

**App (modified):**
- `DiskGallery/App/LicenseStore.swift` — `Status` → `.unconfigured/.free/.licensed`; `isPro`; `isUnlocked(_:)`; real public key; new `LicenseConfig` fields.
- `DiskGallery/App/DiskGalleryApp.swift` — hold a `BetaGate`; show `BetaExpiredView` when expired; gate Export/Import commands.
- `DiskGallery/Views/SettingsView.swift` — `LicenseSettings` reflects the 3-state status.
- `DiskGallery/Views/Modern/ModernSearchPage.swift` — gate saved-search chips.
- `DiskGallery/Views/Modern/ModernDuplicatesPage.swift` — gate filter chips + keep-rule apply.
- `DiskGallery/Views/Modern/ModernActionPlanPage.swift` — gate "Run plan".

**Tools (new):**
- `Tools/dgkeygen/Package.swift` + `Tools/dgkeygen/Sources/dgkeygen/main.swift` — seller-side key issuer.
- `Tools/build-beta-dmg.sh` (modified) — inject `SWIFT_ACTIVE_COMPILATION_CONDITIONS=BETA`.

**Tests (new):**
- `DiskGalleryCoreTests/FeatureTests.swift`
- `DiskGalleryCoreTests/BetaWindowTests.swift`

---

## Task 0: Branch

- [ ] **Step 1: Create the feature branch**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY
git checkout main && git pull --ff-only 2>/dev/null; git checkout -b feat/licensing-and-beta-gate
git status
```

Expected: on `feat/licensing-and-beta-gate`, clean tree.

---

## Task 1: Core — `Feature` enum

**Files:**
- Create: `DiskGalleryCore/Licensing/Feature.swift`
- Test: `DiskGalleryCoreTests/FeatureTests.swift`

- [ ] **Step 1: Write the failing test**

Create `DiskGalleryCoreTests/FeatureTests.swift`:

```swift
import XCTest
@testable import DiskGalleryCore

final class FeatureTests: XCTestCase {
    func testRawValueRoundTrips() {
        for feature in Feature.allCases {
            XCTAssertEqual(Feature(rawValue: feature.rawValue), feature)
        }
    }

    func testEveryFeatureHasNonEmptyDisplayName() {
        for feature in Feature.allCases {
            XCTAssertFalse(feature.displayName.isEmpty, "\(feature) has empty displayName")
        }
    }

    func testExpectedCasesExist() {
        XCTAssertEqual(
            Set(Feature.allCases.map(\.rawValue)),
            ["savedSearches", "keepRuleApply", "bulkTagSync", "dupFilterChips", "exportImport", "transfer"]
        )
    }
}
```

- [ ] **Step 2: Add the test file to the test target and run to verify it fails**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY && xcodegen generate
xcodebuild test -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS' -only-testing:DiskGalleryCoreTests/FeatureTests 2>&1 | tail -20
```

Expected: FAIL — "cannot find 'Feature' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `DiskGalleryCore/Licensing/Feature.swift`:

```swift
import Foundation

/// A premium capability the app gates behind a Pro license. The raw value is a stable
/// identifier (used in analytics/UI keys); `displayName` is the human label shown in the
/// upgrade sheet. The gating *policy* lives in the app's `LicenseStore.isUnlocked(_:)`.
public enum Feature: String, CaseIterable, Sendable {
    case savedSearches
    case keepRuleApply
    case bulkTagSync
    case dupFilterChips
    case exportImport
    case transfer

    public var displayName: String {
        switch self {
        case .savedSearches:  return "Saved searches"
        case .keepRuleApply:  return "Keep-rule auto-marking"
        case .bulkTagSync:    return "Bulk Finder-tag sync"
        case .dupFilterChips: return "Duplicate filters"
        case .exportImport:   return "Export & import library"
        case .transfer:       return "Transfer engine"
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY && xcodegen generate
xcodebuild test -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS' -only-testing:DiskGalleryCoreTests/FeatureTests 2>&1 | tail -20
```

Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add DiskGalleryCore/Licensing/Feature.swift DiskGalleryCoreTests/FeatureTests.swift DiskGallery.xcodeproj
git commit -m "feat(core): add Feature enum for Pro gating"
```

---

## Task 2: Core — `BetaWindow` expiry math

**Files:**
- Create: `DiskGalleryCore/Licensing/BetaWindow.swift`
- Test: `DiskGalleryCoreTests/BetaWindowTests.swift`

Pure value type so the beta hard-stop's date logic is unit-testable without UI or UserDefaults. "14 days from first launch" = `firstLaunch + durationDays*86400`. `daysLeft` rounds up and clamps at 0.

- [ ] **Step 1: Write the failing test**

Create `DiskGalleryCoreTests/BetaWindowTests.swift`:

```swift
import XCTest
@testable import DiskGalleryCore

final class BetaWindowTests: XCTestCase {
    private let day: TimeInterval = 86_400

    func testNotExpiredAtFirstLaunch() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let w = BetaWindow(firstLaunch: start, durationDays: 14)
        XCTAssertFalse(w.isExpired(now: start))
    }

    func testNotExpiredOnLastDay() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let w = BetaWindow(firstLaunch: start, durationDays: 14)
        let day13 = start.addingTimeInterval(13 * day)
        XCTAssertFalse(w.isExpired(now: day13))
    }

    func testExpiredAfterDuration() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let w = BetaWindow(firstLaunch: start, durationDays: 14)
        let day15 = start.addingTimeInterval(15 * day)
        XCTAssertTrue(w.isExpired(now: day15))
    }

    func testExpiresExactlyAtBoundary() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let w = BetaWindow(firstLaunch: start, durationDays: 14)
        XCTAssertTrue(w.isExpired(now: w.expiry))            // >= boundary is expired
    }

    func testDaysLeftCountsDownAndClampsAtZero() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let w = BetaWindow(firstLaunch: start, durationDays: 14)
        XCTAssertEqual(w.daysLeft(now: start), 14)
        XCTAssertEqual(w.daysLeft(now: start.addingTimeInterval(13.5 * day)), 1)
        XCTAssertEqual(w.daysLeft(now: start.addingTimeInterval(20 * day)), 0)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY && xcodegen generate
xcodebuild test -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS' -only-testing:DiskGalleryCoreTests/BetaWindowTests 2>&1 | tail -20
```

Expected: FAIL — "cannot find 'BetaWindow' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `DiskGalleryCore/Licensing/BetaWindow.swift`:

```swift
import Foundation

/// Pure time-window math for the beta hard-stop. "14 days from first launch":
/// the window expires at `firstLaunch + durationDays` and is **inclusive** of the
/// boundary instant (>= expiry counts as expired). No UI, no persistence — the app's
/// `BetaGate` supplies `firstLaunch` (from UserDefaults) and `now`.
public struct BetaWindow: Sendable, Equatable {
    public let firstLaunch: Date
    public let durationDays: Int

    public init(firstLaunch: Date, durationDays: Int = 14) {
        self.firstLaunch = firstLaunch
        self.durationDays = durationDays
    }

    /// The instant the window closes.
    public var expiry: Date {
        firstLaunch.addingTimeInterval(Double(durationDays) * 86_400)
    }

    public func isExpired(now: Date) -> Bool {
        now >= expiry
    }

    /// Whole days remaining, rounded up, clamped to `0`.
    public func daysLeft(now: Date) -> Int {
        let remaining = expiry.timeIntervalSince(now)
        guard remaining > 0 else { return 0 }
        return Int(ceil(remaining / 86_400))
    }
}
```

- [ ] **Step 4: Run to verify it passes**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY && xcodegen generate
xcodebuild test -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS' -only-testing:DiskGalleryCoreTests/BetaWindowTests 2>&1 | tail -20
```

Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add DiskGalleryCore/Licensing/BetaWindow.swift DiskGalleryCoreTests/BetaWindowTests.swift DiskGalleryCore.xcodeproj DiskGallery.xcodeproj 2>/dev/null
git add -A && git commit -m "feat(core): add BetaWindow expiry math"
```

---

## Task 3: Tools — `dgkeygen` key issuer + generate the keypair

**Files:**
- Create: `Tools/dgkeygen/Package.swift`
- Create: `Tools/dgkeygen/Sources/dgkeygen/main.swift`
- Modify: `.gitignore` (ignore the private-key file)

This is seller-side tooling. It wraps the existing `LicenseSigner` (copied as a tiny standalone, since the SPM tool can't link the Xcode framework). The crypto must match `LicenseVerifier` exactly: payload JSON encoded with `.sortedKeys` + `.secondsSince1970`, key = `base64url(payload) + "." + base64url(signature)`.

- [ ] **Step 1: Create the SPM package manifest**

Create `Tools/dgkeygen/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "dgkeygen",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "dgkeygen", path: "Sources/dgkeygen")
    ]
)
```

- [ ] **Step 2: Create the tool source**

Create `Tools/dgkeygen/Sources/dgkeygen/main.swift`:

```swift
import Foundation
import CryptoKit

// MARK: - Crypto (must match DiskGalleryCore/Licensing/LicenseVerifier.swift exactly)

func base64urlEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

struct Payload: Codable {
    var product: String
    var email: String
    var issuedAt: Date
    var expiresAt: Date?
    var seats: Int?
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments
let product = "com.dbarkan.DiskGallery"

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if args.contains("--generate-keypair") {
    let key = Curve25519.Signing.PrivateKey()
    print("PRIVATE (keep secret, set as DG_PRIVATE_KEY):")
    print(key.rawRepresentation.base64EncodedString())
    print("")
    print("PUBLIC (paste into LicenseConfig.publicKeyBase64):")
    print(key.publicKey.rawRepresentation.base64EncodedString())
    exit(0)
}

guard let email = option("--email") else {
    die("""
    usage:
      dgkeygen --generate-keypair
      DG_PRIVATE_KEY=<base64> dgkeygen --email <addr> [--seats N] [--expires YYYY-MM-DD]
    """)
}

guard let privB64 = ProcessInfo.processInfo.environment["DG_PRIVATE_KEY"],
      let privRaw = Data(base64Encoded: privB64),
      let priv = try? Curve25519.Signing.PrivateKey(rawRepresentation: privRaw) else {
    die("Set DG_PRIVATE_KEY to your base64 private key (from --generate-keypair).")
}

var expiresAt: Date?
if let exp = option("--expires") {
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"; fmt.timeZone = TimeZone(identifier: "UTC")
    guard let d = fmt.date(from: exp) else { die("--expires must be YYYY-MM-DD") }
    expiresAt = d
}
let seats = option("--seats").flatMap(Int.init)

let payload = Payload(product: product, email: email, issuedAt: Date(),
                      expiresAt: expiresAt, seats: seats)

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .secondsSince1970
encoder.outputFormatting = [.sortedKeys]
let payloadData = try encoder.encode(payload)
let signature = try priv.signature(for: payloadData)
print(base64urlEncode(payloadData) + "." + base64urlEncode(signature))
```

- [ ] **Step 3: Build the tool and generate the keypair**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY/Tools/dgkeygen
swift run dgkeygen --generate-keypair
```

Expected: prints a PRIVATE and a PUBLIC base64 key. **Record both** — the PUBLIC key is needed in Task 4; the PRIVATE key must be saved securely (password manager) and never committed.

- [ ] **Step 4: Verify the tool round-trips against the real verifier**

Mint a key with the generated private key and confirm `LicenseVerifier` (in Core) accepts it. Run from the repo root, substituting the PRIVATE key from Step 3:

```bash
cd /Users/mrbarkan/Development/DISKGALLERY/Tools/dgkeygen
DG_PRIVATE_KEY="<PRIVATE-from-step-3>" swift run dgkeygen --email test@example.com
```

Expected: prints a `<base64url>.<base64url>` license key. (Full end-to-end verification against `LicenseVerifier` happens in Task 4's build with the embedded public key; this step just confirms the tool emits a well-formed key.)

- [ ] **Step 5: Ignore the private key + commit the tool**

Append to `.gitignore`:

```
# Seller-side license private key — NEVER commit
dg-private-key.txt
Tools/dgkeygen/.build/
```

```bash
cd /Users/mrbarkan/Development/DISKGALLERY
git add Tools/dgkeygen/Package.swift Tools/dgkeygen/Sources/dgkeygen/main.swift .gitignore
git commit -m "feat(tools): add dgkeygen license key issuer"
```

---

## Task 4: App — rewrite `LicenseStore` for freemium + embed public key

**Files:**
- Modify: `DiskGallery/App/LicenseStore.swift` (full rewrite of `LicenseConfig` + `LicenseStore`)

Replaces the trial model with freemium. `Status` becomes `.unconfigured / .free / .licensed`. Verified by build (no app unit-test target; logic it depends on — `LicenseVerifier` — is already Core-tested).

- [ ] **Step 1: Rewrite the file**

Replace the entire contents of `DiskGallery/App/LicenseStore.swift` with (paste the PUBLIC key from Task 3 Step 3 into `publicKeyBase64`):

```swift
import Foundation
import Observation
import DiskGalleryCore

/// Build-time licensing configuration.
enum LicenseConfig {
    static let product = "com.dbarkan.DiskGallery"

    /// Ed25519 **public** key (base64). Empty ⇒ licensing disabled ⇒ everything unlocked
    /// (dev builds). Paired private key lives only in the seller's `dgkeygen` env.
    static let publicKeyBase64 = "PASTE_PUBLIC_KEY_FROM_DGKEYGEN"

    /// One-time Pro price, shown in the upgrade sheet. Configurable; nothing depends on the value.
    static let proPrice = "$19"

    /// Where "Buy" sends people.
    static let buyURL = URL(string: "https://diskgallery.app")!
    /// Where the expired-beta "Check for update" button sends people (Sparkle-ready later).
    static let updatesURL = URL(string: "https://diskgallery.app/download")!
    /// Where the expired-beta "Send feedback" button sends people.
    static let feedbackURL = URL(string: "https://diskgallery.app/feedback")!
}

/// Tracks freemium license state. Verification is fully offline via `LicenseVerifier`.
/// Free tier is perpetual; Pro is a one-time unlock. No trial.
@MainActor
@Observable
final class LicenseStore {
    enum Status: Equatable {
        case unconfigured            // no public key in this build → licensing disabled
        case free                    // configured, no valid key → free tier
        case licensed(email: String)
    }

    private let verifier: LicenseVerifier?
    private let defaults: UserDefaults
    private let keyDefaultsKey = "license.key"

    private(set) var status: Status = .unconfigured

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        verifier = try? LicenseVerifier(product: LicenseConfig.product,
                                        publicKeyBase64: LicenseConfig.publicKeyBase64)
        refresh()
    }

    /// Premium features unlocked? True for unconfigured (dev) and licensed; false for free.
    var isPro: Bool {
        switch status {
        case .unconfigured, .licensed: return true
        case .free:                    return false
        }
    }

    /// Single call site for gating. Uniform policy today (== isPro); the `Feature`
    /// argument lets the policy vary per-feature later without touching callers.
    func isUnlocked(_ feature: Feature) -> Bool { isPro }

    var licenseEmail: String? {
        if case .licensed(let email) = status { return email }
        return nil
    }

    func refresh() {
        guard let verifier else { status = .unconfigured; return }
        if let key = defaults.string(forKey: keyDefaultsKey), let payload = try? verifier.verify(key) {
            status = .licensed(email: payload.email)
        } else {
            status = .free
        }
    }

    /// Activates a pasted key. Returns nil on success, or a human-readable error.
    @discardableResult
    func activate(_ key: String) -> String? {
        guard let verifier else { return LicenseError.notConfigured.errorDescription }
        do {
            let payload = try verifier.verify(key)
            defaults.set(key, forKey: keyDefaultsKey)
            status = .licensed(email: payload.email)
            return nil
        } catch {
            return (error as? LicenseError)?.errorDescription ?? error.localizedDescription
        }
    }

    func deactivate() {
        defaults.removeObject(forKey: keyDefaultsKey)
        refresh()
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY
xcodebuild build -project DiskGallery.xcodeproj -scheme DiskGallery -destination 'platform=macOS' 2>&1 | tail -25
```

Expected: `** BUILD SUCCEEDED **`. (Compile errors at the `aboutLicense`/`aboutLicensee` switches in `DiskGalleryApp.swift` are expected and fixed in Task 7; if the build fails ONLY there, proceed — Task 7 resolves it. If it fails elsewhere, fix before continuing.)

> Note: because `DiskGalleryApp.swift` still references `.trial`/`.trialExpired`, this build will not fully succeed until Task 7. That is expected. To keep commits green, this task is committed together with Task 7's app wiring. **Do not commit yet** — continue to Task 5.

---

## Task 5: App — `BetaGate` observable wrapper

**Files:**
- Create: `DiskGallery/App/BetaGate.swift`

Wraps `BetaWindow` + UserDefaults. Under `#if BETA` it records first-launch and reports expiry; otherwise it is inert.

- [ ] **Step 1: Create the file**

Create `DiskGallery/App/BetaGate.swift`:

```swift
import Foundation
import Observation
import DiskGalleryCore

/// The build-specific beta hard-stop. Active only in builds compiled with the `BETA`
/// flag (the beta DMG). Records first-launch in UserDefaults and reports expiry via the
/// pure `BetaWindow`. In non-beta builds it is inert (`isExpired == false`).
@MainActor
@Observable
final class BetaGate {
    private let firstLaunchKey = "beta.firstLaunch"
    private let durationDays = 14
    private let defaults: UserDefaults

    private(set) var isExpired = false
    private(set) var daysLeft = 0

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        #if BETA
        let firstLaunch: Date
        if let stored = defaults.object(forKey: firstLaunchKey) as? Date {
            firstLaunch = stored
        } else {
            firstLaunch = now                          // fail-open: never expire on day one
            defaults.set(now, forKey: firstLaunchKey)
        }
        let window = BetaWindow(firstLaunch: firstLaunch, durationDays: durationDays)
        isExpired = window.isExpired(now: now)
        daysLeft = window.daysLeft(now: now)
        #endif
    }
}
```

- [ ] **Step 2: Regenerate (new file) — defer build to Task 7**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY && xcodegen generate
```

Expected: success. (Build verification happens at the end of Task 7 once all app wiring is in place.)

---

## Task 6: App — `UpgradeSheet` + `ProBadge`/`proGated`

**Files:**
- Create: `DiskGallery/Views/Upgrade/UpgradeSheet.swift`
- Create: `DiskGallery/Views/Upgrade/ProBadge.swift`

- [ ] **Step 1: Create the upgrade sheet**

Create `DiskGallery/Views/Upgrade/UpgradeSheet.swift`:

```swift
import SwiftUI
import AppKit
import DiskGalleryCore

/// The single shared "Unlock DiskGallery Pro" sheet. Reached from any `.proGated`
/// control and from Settings. Buy opens the store; the field activates a pasted key.
struct UpgradeSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var error: String?

    /// The feature the user was reaching for (drives the headline). Optional.
    var feature: Feature?

    private let proFeatures: [String] = [
        "Saved searches", "Duplicate filters & keep-rule auto-marking",
        "Bulk Finder-tag sync", "Export & import your library",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Unlock DiskGallery Pro").font(.title2.bold())
                if let feature {
                    Text("\(feature.displayName) is a Pro feature.").foregroundStyle(.secondary)
                } else {
                    Text("A one-time purchase. Yours forever.").foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(proFeatures, id: \.self) { item in
                    Label(item, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.primary)
                }
            }
            .font(.callout)

            Button {
                NSWorkspace.shared.open(LicenseConfig.buyURL)
            } label: {
                Text("Buy Pro — \(LicenseConfig.proPrice)").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Already have a license key?").font(.callout.weight(.medium))
                TextField("Paste your license key", text: $key, axis: .vertical)
                    .lineLimit(2...4)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                    Button("Activate") {
                        error = env.license.activate(key)
                        if error == nil { dismiss() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
```

- [ ] **Step 2: Create the PRO badge + modifier**

Create `DiskGallery/Views/Upgrade/ProBadge.swift`:

```swift
import SwiftUI
import DiskGalleryCore

/// Small "PRO" lock chip overlaid on gated controls.
struct ProBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "lock.fill").font(.system(size: 8, weight: .bold))
            Text("PRO").font(.system(size: 9, weight: .heavy)).tracking(0.5)
        }
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(Capsule().fill(.tint))
        .foregroundStyle(.white)
    }
}

private struct ProGate: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    let feature: Feature
    @State private var showSheet = false

    func body(content: Content) -> some View {
        let unlocked = env.license.isUnlocked(feature)
        content
            .overlay(alignment: .topTrailing) {
                if !unlocked { ProBadge().offset(x: 6, y: -8) }
            }
            // When locked, a transparent overlay on top captures every tap before the
            // underlying control can act, and opens the upgrade sheet instead.
            .overlay {
                if !unlocked {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { showSheet = true }
                }
            }
            .sheet(isPresented: $showSheet) { UpgradeSheet(feature: feature).environment(env) }
    }
}

extension View {
    /// Marks a control as Pro: shows a PRO badge and, when locked, intercepts taps to
    /// present the upgrade sheet instead of running the underlying action.
    func proGated(_ feature: Feature) -> some View {
        modifier(ProGate(feature: feature))
    }
}
```

- [ ] **Step 3: Regenerate (new files) — defer build to Task 7**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY && xcodegen generate
```

Expected: success.

---

## Task 7: App — `BetaExpiredView` + wire `BetaGate`/license into `DiskGalleryApp`

**Files:**
- Create: `DiskGallery/Views/Brand/BetaExpiredView.swift`
- Modify: `DiskGallery/App/DiskGalleryApp.swift`

This task also fixes the `.trial`/`.trialExpired` references broken by Task 4, so the app builds green again. **Commit Tasks 4–7 together at the end of this task.**

- [ ] **Step 1: Create the expiry screen**

Create `DiskGallery/Views/Brand/BetaExpiredView.swift`:

```swift
import SwiftUI
import AppKit
import DiskGalleryCore

/// Full-window block shown when a BETA build's 14-day window has closed. The catalog is
/// never opened behind it. Offers an update link and a feedback link.
struct BetaExpiredView: View {
    private let accent = BrandPalette.violet.accent

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "hourglass.bottomhalf.filled")
                .font(.system(size: 54)).foregroundStyle(accent)
            Text("This beta has expired").font(.title.bold())
            Text("Thanks for testing DiskGallery. This pre-release build has reached its 14-day limit. Grab the latest version to keep going.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.open(LicenseConfig.updatesURL)
                } label: { Text("Check for update").frame(minWidth: 130) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                Button {
                    NSWorkspace.shared.open(LicenseConfig.feedbackURL)
                } label: { Text("Send feedback").frame(minWidth: 130) }
                .controlSize(.large)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .dark)
    }
}
```

- [ ] **Step 2: Wire the beta gate + fix the license switches in `DiskGalleryApp.swift`**

In `DiskGallery/App/DiskGalleryApp.swift`:

(a) Add a `BetaGate` state alongside `env`. Change:

```swift
    @State private var env: AppEnvironment? = try? AppEnvironment()
    @State private var systemAppearance = SystemAppearance()
    @State private var launching = true
```

to:

```swift
    @State private var env: AppEnvironment? = try? AppEnvironment()
    @State private var betaGate = BetaGate()
    @State private var systemAppearance = SystemAppearance()
    @State private var launching = true
```

(b) Gate the root content. Replace the `ZStack { if let env { ContentView()... } ... }` block's `ContentView().environment(env)` line so the expired screen wins:

```swift
                if betaGate.isExpired {
                    BetaExpiredView()
                } else if let env {
                    ContentView().environment(env)
                } else {
                    ContentUnavailableView("Couldn't open the catalog",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text("The DiskGallery database could not be created."))
                }
```

(c) Fix the two license switches (they still reference removed cases). Replace `aboutLicensee`:

```swift
    private var aboutLicensee: String {
        switch env?.license.status {
        case .licensed(let email):  return email
        case .free:                 return "Free"
        case .unconfigured, .none:  return "—"
        }
    }
```

and `aboutLicense`:

```swift
    private var aboutLicense: String {
        switch env?.license.status {
        case .licensed:             return "Pro · Perpetual"
        case .free:                 return "Free"
        case .unconfigured, .none:  return "Unlicensed"
        }
    }
```

(d) Gate Export/Import commands. Replace the `CommandGroup(after: .newItem)` block:

```swift
            CommandGroup(after: .newItem) {
                Divider()
                Button("Export Library…") {
                    if env?.license.isUnlocked(.exportImport) == true { env?.exportLibrary() }
                    else { env?.requestUpgrade(.exportImport) }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Import Library…") {
                    if env?.license.isUnlocked(.exportImport) == true { env?.importLibrary() }
                    else { env?.requestUpgrade(.exportImport) }
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
```

- [ ] **Step 3: Add the upgrade-request hook to `AppEnvironment`**

Menu commands can't present a SwiftUI sheet directly. Add a published trigger to `AppEnvironment` that `ContentView` observes. In `DiskGallery/App/AppEnvironment.swift`, add a property near the other `var` state (after `var errorMessage: String?`):

```swift
    var upgradeFeature: Feature?     // non-nil ⇒ show the upgrade sheet for this feature
```

and a method (near the other functions):

```swift
    func requestUpgrade(_ feature: Feature) { upgradeFeature = feature }
```

Then in `DiskGallery/App/DiskGalleryApp.swift`, present the sheet from `ContentView`. Add to the `ContentView` body's modifier chain (after the existing `.alert(...)`):

```swift
        .sheet(item: Binding(get: { env.upgradeFeature.map { FeatureBox($0) } },
                             set: { env.upgradeFeature = $0?.feature })) { box in
            UpgradeSheet(feature: box.feature)
                .environment(env)
        }
```

and add this small Identifiable wrapper at the bottom of `DiskGalleryApp.swift` (sheets need `Identifiable`):

```swift
/// Wraps a `Feature` so it can drive a `.sheet(item:)`.
struct FeatureBox: Identifiable { let feature: Feature; var id: String { feature.rawValue }
    init(_ feature: Feature) { self.feature = feature } }
```

- [ ] **Step 4: Build the app (full app wiring now complete)**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY && xcodegen generate
xcodebuild build -project DiskGallery.xcodeproj -scheme DiskGallery -destination 'platform=macOS' 2>&1 | tail -25
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit Tasks 4–7 together**

```bash
git add -A
git commit -m "feat(app): freemium LicenseStore, BetaGate, upgrade sheet, beta-expired screen"
```

---

## Task 8: App — gate the Pro controls on the Modern pages

**Files:**
- Modify: `DiskGallery/Views/Modern/ModernSearchPage.swift:102` (`savedSearchChips`)
- Modify: `DiskGallery/Views/Modern/ModernDuplicatesPage.swift` (`DupSetsCard` chips ~line 108; `keepRuleSection` ~line 296)
- Modify: `DiskGallery/Views/Modern/ModernActionPlanPage.swift` (`ExecutePlanCard` "Run plan" ~line 205)

Add `.proGated(...)` to each Pro control's container. The modifier shows the badge and intercepts taps when locked.

- [ ] **Step 1: Gate saved-search chips**

In `ModernSearchPage.swift`, the `savedSearchChips` computed view wraps a row of `ModernFilterChip`s. Add `.proGated(.savedSearches)` to its outer container. Find the `private var savedSearchChips: some View {` body and append `.proGated(.savedSearches)` to the outermost view it returns (the `HStack`/`FlowChips` wrapper).

```swift
    private var savedSearchChips: some View {
        // ... existing body ...
        .proGated(.savedSearches)
    }
```

- [ ] **Step 2: Gate duplicate filter chips + keep-rule**

In `ModernDuplicatesPage.swift`:

- In `DupSetsCard`, the chips `ScrollView`/`HStack` (the `ForEach(chips...)` container ~line 108) gets `.proGated(.dupFilterChips)` on its outer container.
- In `ResolveSetCard.keepRuleSection` (~line 296), add `.proGated(.keepRuleApply)` to the `VStack` it returns.

```swift
    private var keepRuleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // ... existing ...
        }
        .proGated(.keepRuleApply)
    }
```

- [ ] **Step 3: Gate "Run plan"**

In `ModernActionPlanPage.swift`, `ExecutePlanCard` (~line 205) renders the "Run plan" `CTAButton`. Wrap that button with `.proGated(.bulkTagSync)`:

```swift
                        CTAButton(title: running ? "Writing Finder tags…" : "Run plan",
                                  /* existing args */ )
                        .proGated(.bulkTagSync)
```

- [ ] **Step 4: Build to verify**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY
xcodebuild build -project DiskGallery.xcodeproj -scheme DiskGallery -destination 'platform=macOS' 2>&1 | tail -25
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(app): gate Pro controls on Modern pages with proGated"
```

---

## Task 9: App — update `LicenseSettings` for the 3-state status

**Files:**
- Modify: `DiskGallery/Views/SettingsView.swift:53-65` (`statusRow`)

The current `statusRow` switches over `.trial`/`.trialExpired` (removed). Update it.

- [ ] **Step 1: Replace `statusRow`**

In `DiskGallery/Views/SettingsView.swift`, replace the `statusRow` computed property:

```swift
    @ViewBuilder private var statusRow: some View {
        switch env.license.status {
        case .unconfigured:
            Label("Licensing not configured — all features unlocked", systemImage: "lock.open")
                .foregroundStyle(.secondary)
        case .free:
            Label("Free — upgrade to Pro to unlock the power tools", systemImage: "person")
        case .licensed(let email):
            Label("DiskGallery Pro — licensed to \(email)", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        }
    }
```

- [ ] **Step 2: Build to verify**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY
xcodebuild build -project DiskGallery.xcodeproj -scheme DiskGallery -destination 'platform=macOS' 2>&1 | tail -25
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat(app): freemium status in License settings"
```

---

## Task 10: Beta build flag + final verification

**Files:**
- Modify: `Tools/build-beta-dmg.sh` (inject `BETA` compilation condition)

- [ ] **Step 1: Inject the BETA flag into the beta archive**

In `Tools/build-beta-dmg.sh`, the `xcodebuild archive` invocation has a list of build-setting overrides. Add a `SWIFT_ACTIVE_COMPILATION_CONDITIONS` override so only the beta DMG defines `BETA`:

Find:

```bash
  CODE_SIGN_IDENTITY="Developer ID Application" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
```

Replace with:

```bash
  CODE_SIGN_IDENTITY="Developer ID Application" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS="BETA" \
```

- [ ] **Step 2: Run the full Core test suite (regression)**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY && xcodegen generate
xcodebuild test -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS' 2>&1 | tail -15
```

Expected: `** TEST SUCCEEDED **`, all tests pass (previous 63 + 8 new = 71+).

- [ ] **Step 3: Release build (no BETA) sanity check**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY
xcodebuild build -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Release -destination 'platform=macOS' 2>&1 | tail -15
```

Expected: `** BUILD SUCCEEDED **` (this is the App-Store/direct-release shape — no beta gate).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "build: define BETA compilation condition for beta DMG"
```

- [ ] **Step 5: Build the notarized beta DMG (with BETA gate active)**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY
Tools/build-beta-dmg.sh 2>&1 | tail -20
```

Expected: notary `status: Accepted`, staple OK, `spctl ... accepted`, `build/DiskGallery-beta.dmg` produced — now with the 14-day hard-stop compiled in.

---

## Manual verification (after merge)

These need a human at the keyboard (no app unit-test target):

1. **Free → Pro:** Launch a non-beta debug build. With `publicKeyBase64` set, status shows **Free**; Pro controls show PRO badges; clicking one opens the upgrade sheet. Paste a key minted by `dgkeygen` → status flips to **Pro**, badges disappear, controls work. Deactivate in Settings → back to **Free**.
2. **Beta expiry:** In a `BETA` build, set `UserDefaults` `beta.firstLaunch` to 20 days ago (`defaults write com.dbarkan.DiskGallery beta.firstLaunch -date "..."`), relaunch → `BetaExpiredView` blocks the app; buttons open the update/feedback URLs.
3. **Dev safety net:** Temporarily blank `publicKeyBase64` → status **unconfigured**, everything unlocked (no badges).
