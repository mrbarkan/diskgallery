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
