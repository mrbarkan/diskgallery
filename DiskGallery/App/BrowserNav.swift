import Foundation
import Observation
import DiskGalleryCore

/// Drill-down navigation state for one drive's tree browser. Folders open on
/// double-click via `open(_:)`.
@MainActor
@Observable
final class BrowserNav {
    var path: [Entry] = []
    func open(_ entry: Entry) { path.append(entry) }
}
