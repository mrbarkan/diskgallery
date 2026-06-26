import SwiftUI

struct GalleryView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ContentUnavailableView("Gallery", systemImage: "square.grid.3x3.fill",
                               description: Text("Your cross-drive contact sheet."))
            .navigationTitle("Gallery")
    }
}
