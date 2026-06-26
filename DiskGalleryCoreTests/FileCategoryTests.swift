import XCTest
@testable import DiskGalleryCore

final class FileCategoryTests: XCTestCase {

    func testExtensionMapping() {
        XCTAssertEqual(FileCategory.category(forExtension: "CR2"), .raw)
        XCTAssertEqual(FileCategory.category(forExtension: "jpeg"), .photos)
        XCTAssertEqual(FileCategory.category(forExtension: "MOV"), .video)
        XCTAssertEqual(FileCategory.category(forExtension: "pdf"), .documents)
    }

    func testUnknownAndEmptyExtensionAreAll() {
        XCTAssertEqual(FileCategory.category(forExtension: "xyz"), .all)
        XCTAssertEqual(FileCategory.category(forExtension: ""), .all)
    }

    func testMatchesFilename() {
        XCTAssertTrue(FileCategory.raw.matches(filename: "IMG_0001.NEF"))
        XCTAssertFalse(FileCategory.raw.matches(filename: "IMG_0001.jpg"))
        XCTAssertTrue(FileCategory.photos.matches(filename: "pic.heic"))
        XCTAssertTrue(FileCategory.all.matches(filename: "README"))
        XCTAssertTrue(FileCategory.all.matches(filename: "movie.mov"))
        XCTAssertFalse(FileCategory.documents.matches(filename: "README"))
    }

    func testLabels() {
        XCTAssertEqual(FileCategory.allCases.map(\.label),
                       ["All", "Photos", "Video", "RAW", "Documents", "Audio"])
    }
}
