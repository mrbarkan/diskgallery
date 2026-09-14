import SwiftUI
import AppKit
import DiskGalleryCore

/// What the user picked under the Export Drive Map save panel.
@Observable final class DriveMapExportChoices {
    var includeFiles = true
    var filesPerFolder: Int? = 20
    var hideHidden = true

    func options(appVersion: String) -> DriveMapOptions {
        DriveMapOptions(includeFiles: includeFiles, filesPerFolder: filesPerFolder,
                        hideHidden: hideHidden, appVersion: appVersion)
    }
}

/// Accessory controls for the Export Drive Map save panel.
struct DriveMapExportOptionsView: View {
    @Bindable var choices: DriveMapExportChoices

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Include file samples", isOn: $choices.includeFiles)
            Picker("Files per folder", selection: $choices.filesPerFolder) {
                Text("20").tag(Int?.some(20))
                Text("50").tag(Int?.some(50))
                Text("100").tag(Int?.some(100))
                Text("All").tag(Int?.none)
            }
            .pickerStyle(.menu)
            .frame(width: 220)
            .disabled(!choices.includeFiles)
            Text("Each folder lists its largest files. All can make a very large map.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Hide hidden files and folders", isOn: $choices.hideHidden)
        }
        .padding(12)
        .frame(width: 380, alignment: .leading)
    }

    static func accessory(for choices: DriveMapExportChoices) -> NSView {
        let host = NSHostingView(rootView: DriveMapExportOptionsView(choices: choices))
        host.frame.size = host.fittingSize
        return host
    }
}
