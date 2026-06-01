import SwiftUI
import AppKit
import DiskGalleryCore

/// The single shared "Unlock DiskGallery Pro" sheet. Reached from any `.proGated`
/// control and from Settings. Buy opens the store; the field activates a pasted key.
struct UpgradeSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var error: String?

    /// The feature the user was reaching for (drives the headline). Optional.
    var feature: Feature?

    private let proFeatures: [String] = [
        "Saved searches", "Duplicate filters & keep-rule auto-marking",
        "Bulk Finder-tag sync", "Export & import your library",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Unlock DiskGallery Pro").font(.title2.bold())
                if let feature {
                    Text("\(feature.displayName) is a Pro feature.").foregroundStyle(.secondary)
                } else {
                    Text("A one-time purchase. Yours forever.").foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(proFeatures, id: \.self) { item in
                    Label(item, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.primary)
                }
            }
            .font(.callout)

            Button {
                NSWorkspace.shared.open(LicenseConfig.buyURL)
            } label: {
                Text("Buy Pro — \(LicenseConfig.proPrice)").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Already have a license key?").font(.callout.weight(.medium))
                TextField("Paste your license key", text: $key, axis: .vertical)
                    .lineLimit(2...4)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                    Button("Activate") {
                        error = env.license.activate(key)
                        if error == nil { dismiss() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
