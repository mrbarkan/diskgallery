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
