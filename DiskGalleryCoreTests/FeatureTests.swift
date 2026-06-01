import XCTest
@testable import DiskGalleryCore

final class FeatureTests: XCTestCase {
    func testDisplayNamesAreCorrect() {
        XCTAssertEqual(Feature.transfer.displayName, "Transfer engine")
        XCTAssertEqual(Feature.savedSearches.displayName, "Saved searches")
        XCTAssertEqual(Feature.bulkTagSync.displayName, "Bulk Finder-tag sync")
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
