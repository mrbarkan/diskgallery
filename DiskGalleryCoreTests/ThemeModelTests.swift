import XCTest
@testable import DiskGalleryCore

final class ThemeModelTests: XCTestCase {

    func testLegacyThemeMigrationMapsAllKnownValues() {
        XCTAssertEqual(ThemeMigration.accent(fromLegacy: "graphite"), .graphite)
        XCTAssertEqual(ThemeMigration.accent(fromLegacy: "grape"),    .violet)
        XCTAssertEqual(ThemeMigration.accent(fromLegacy: "ocean"),    .blue)
        XCTAssertEqual(ThemeMigration.accent(fromLegacy: "forest"),   .green)
        XCTAssertEqual(ThemeMigration.accent(fromLegacy: "sunset"),   .amber)
        XCTAssertEqual(ThemeMigration.accent(fromLegacy: "rose"),     .coral)
    }

    func testLegacyMigrationDefaultsToVioletForUnknownOrNil() {
        XCTAssertEqual(ThemeMigration.accent(fromLegacy: nil), .violet)
        XCTAssertEqual(ThemeMigration.accent(fromLegacy: ""), .violet)
        XCTAssertEqual(ThemeMigration.accent(fromLegacy: "chartreuse"), .violet)
    }

    func testRawValuesAreStableForPersistence() {
        XCTAssertEqual(Skin.allCases.map(\.rawValue), ["classic", "modern"])
        XCTAssertEqual(Accent.allCases.map(\.rawValue),
                       ["graphite", "violet", "blue", "green", "amber", "coral"])
        XCTAssertEqual(OLEDLayout.allCases.map(\.rawValue),
                       ["telemetry", "minimal", "actionDetail"])
    }

    func testGaugeLayoutRemoved() {
        XCTAssertNil(OLEDLayout(rawValue: "gauge"))
    }

    func testDisplayNames() {
        XCTAssertEqual(Skin.classic.name, "Classic")
        XCTAssertEqual(Skin.modern.name, "Modern")
        XCTAssertEqual(Accent.violet.name, "Violet")
        XCTAssertEqual(OLEDLayout.telemetry.name, "Telemetry")
        XCTAssertEqual(OLEDLayout.actionDetail.name, "Action")
    }
}
