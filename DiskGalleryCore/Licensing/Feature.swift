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
