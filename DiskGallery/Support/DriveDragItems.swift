import Foundation
import UniformTypeIdentifiers
import CoreTransferable

/// Private drag identifiers, scoped to this app. Used only for in-process sidebar
/// reordering — declaring them at runtime is enough and avoids matching external
/// file drags (which arrive as `public.file-url`, not these types).
extension UTType {
    static let dgDrive = UTType(exportedAs: "com.dbarkan.DiskGallery.drive-id")
    static let dgDriveGroup = UTType(exportedAs: "com.dbarkan.DiskGallery.group-id")
}

/// A drive being dragged in the sidebar (carries its volume id).
struct DriveDragPayload: Codable, Transferable {
    let volumeId: Int64
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .dgDrive)
    }
}

/// A group header being dragged to reorder sections (carries its group id).
struct GroupDragPayload: Codable, Transferable {
    let groupId: Int64
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .dgDriveGroup)
    }
}
