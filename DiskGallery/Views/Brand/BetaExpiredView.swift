import SwiftUI
import AppKit
import DiskGalleryCore

/// Full-window block shown when a BETA build's 14-day window has closed. The catalog is
/// never opened behind it. Offers an update link and a feedback link.
struct BetaExpiredView: View {
    private let accent = BrandPalette.violet.accent

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "hourglass.bottomhalf.filled")
                .font(.system(size: 54)).foregroundStyle(accent)
            Text("This beta has expired").font(.title.bold())
            Text("Thanks for testing DiskGallery. This pre-release build has reached its 14-day limit. Grab the latest version to keep going.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.open(LicenseConfig.updatesURL)
                } label: { Text("Check for update").frame(minWidth: 130) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                Button {
                    NSWorkspace.shared.open(LicenseConfig.feedbackURL)
                } label: { Text("Send feedback").frame(minWidth: 130) }
                .controlSize(.large)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .dark)
    }
}
