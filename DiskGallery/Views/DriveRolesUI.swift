import SwiftUI
import DiskGalleryCore

/// A "Set Role" submenu for a drive — reused by both sidebars' context menus.
struct DriveRoleMenu: View {
    @Environment(AppEnvironment.self) private var env
    let key: String

    var body: some View {
        Menu("Set Role") {
            let current = env.role(forKey: key)
            ForEach(DriveRole.displayOrder, id: \.self) { role in
                Button {
                    env.setDriveRole(role, forKey: key)
                } label: {
                    Label(env.roleLabels.label(for: role),
                          systemImage: role == current ? "checkmark" : role.symbol)
                }
            }
        }
    }
}

/// Settings → Drives: assign roles, set priority order, and rename role labels.
struct DrivesSettings: View {
    @Environment(AppEnvironment.self) private var env

    private var orderedDrives: [VolumeSummary] {
        env.volumeSummaries.sorted {
            let pa = env.priority(forKey: $0.uuid ?? $0.name)
            let pb = env.priority(forKey: $1.uuid ?? $1.name)
            if pa != pb { return pa < pb }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        Form {
            Section {
                if env.volumeSummaries.isEmpty {
                    Text("No drives catalogued yet.").foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(orderedDrives) { DriveRoleSettingsRow(drive: $0) }
                            .onMove(perform: movePriority)
                    }
                    .frame(minHeight: 180)
                }
            } header: {
                Text("Drives")
            } footer: {
                Text("Roles steer the Organize plan's suggested destinations. Drag to set priority — higher in the list is filled first. Nothing is ever moved automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(DriveRole.displayOrder, id: \.self) { RoleLabelRow(role: $0) }
                Button("Reset Names to Defaults") { env.roleLabels.resetToDefaults() }
            } header: {
                Text("Role Names")
            } footer: {
                Text("Rename any role to match your setup (e.g. “Work / Scratch” → “Editing NVMe”). Behaviors stay the same.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func movePriority(from source: IndexSet, to destination: Int) {
        var drives = orderedDrives
        drives.move(fromOffsets: source, toOffset: destination)
        for (index, drive) in drives.enumerated() {
            env.setDrivePriority(index, forKey: drive.uuid ?? drive.name)
        }
    }
}

private struct DriveRoleSettingsRow: View {
    @Environment(AppEnvironment.self) private var env
    let drive: VolumeSummary
    private var key: String { drive.uuid ?? drive.name }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: env.role(forKey: key).symbol).foregroundStyle(.secondary).frame(width: 18)
            Text(drive.name).lineLimit(1)
            Spacer(minLength: 8)
            Picker("", selection: Binding(
                get: { env.role(forKey: key) },
                set: { env.setDriveRole($0, forKey: key) })) {
                ForEach(DriveRole.displayOrder, id: \.self) { role in
                    Text(env.roleLabels.label(for: role)).tag(role)
                }
            }
            .labelsHidden().frame(width: 170)
        }
    }
}

private struct RoleLabelRow: View {
    @Environment(AppEnvironment.self) private var env
    let role: DriveRole

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: role.symbol).foregroundStyle(.secondary).frame(width: 18)
            TextField(role.defaultLabel, text: Binding(
                get: { env.roleLabels.label(for: role) },
                set: { env.roleLabels.setLabel($0, for: role) }))
            .textFieldStyle(.roundedBorder)
        }
    }
}
