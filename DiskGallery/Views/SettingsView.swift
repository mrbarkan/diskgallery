import SwiftUI
import AppKit
import DiskGalleryCore

struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            ShortcutSettings()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            DrivesSettings()
                .tabItem { Label("Drives", systemImage: "externaldrive.badge.checkmark") }
            FilesSettings()
                .tabItem { Label("Files", systemImage: "doc") }
            LicenseSettings()
                .tabItem { Label("License", systemImage: "checkmark.seal") }
        }
        .frame(width: 480, height: 520)
    }
}

struct LicenseSettings: View {
    @Environment(AppEnvironment.self) private var env
    @State private var key = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section("Status") { statusRow }
            Section("Activate a License Key") {
                TextField("Paste your license key", text: $key, axis: .vertical)
                    .lineLimit(2...4)
                    .font(.system(.body, design: .monospaced))
                HStack {
                    Button("Activate") {
                        error = env.license.activate(key)
                        if error == nil { key = "" }
                    }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if env.license.licenseEmail != nil {
                        Button("Deactivate", role: .destructive) { env.license.deactivate() }
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            if AppInfo.websiteIsLive {
                Section {
                    Button("Buy DiskGallery…") { NSWorkspace.shared.open(LicenseConfig.buyURL) }
                } footer: {
                    Text("DiskGallery will be available on the Mac App Store and direct from \(LicenseConfig.buyURL.host ?? "our site"). License keys are verified on your Mac — no internet required.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var statusRow: some View {
        switch env.license.status {
        case .unconfigured:
            Label("Licensing not configured — all features unlocked", systemImage: "lock.open")
                .foregroundStyle(.secondary)
        case .free:
            Label("Free — upgrade to Pro to unlock the power tools", systemImage: "person")
        case .licensed(let email):
            Label("DiskGallery Pro — licensed to \(email)", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        }
    }
}

struct FilesSettings: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var prefs = env.viewPrefs
        Form {
            Section {
                Toggle("Hide hidden files and folders", isOn: $prefs.hideHidden)
            } footer: {
                Text("Hides dotfiles (names starting with “.”) such as .DS_Store and .Trashes from the browser, search, and duplicates. Files are still catalogued — only hidden from view.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Restore last view on launch", isOn: $prefs.restoreLastView)
            } footer: {
                Text("Reopen DiskGallery on whatever view you had selected last time. Turn off to always open on the first drive.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AppearanceSettings: View {
    @Environment(AppEnvironment.self) private var env

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 12)]

    var body: some View {
        @Bindable var theme = env.theme
        Form {
            Section("Look") {
                Picker("Skin", selection: $theme.skin) {
                    ForEach(Skin.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Section("Mode") {
                Picker("Appearance", selection: $theme.mode) {
                    ForEach(AppearanceMode.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Section("Accent") {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Accent.allCases) { option in
                        Button { theme.accent = option } label: {
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(option.palette.accent)
                                    .frame(width: 36, height: 36)
                                    .overlay(Circle().strokeBorder(theme.accent == option ? Color.primary : .clear, lineWidth: 2.5))
                                Text(option.name).font(.caption)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                Picker("Layout", selection: $theme.oledLayout) {
                    ForEach(OLEDLayout.userSelectable) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(theme.skin == .classic)
            } header: {
                Text("OLED Display")
            } footer: {
                Text("The OLED drive display appears in the Modern look.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .tint(env.theme.accent.palette.accent)
    }
}

struct ShortcutSettings: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.decisionActions) { ShortcutRow(action: $0) }
            } header: {
                Text("Action Tags")
            } footer: {
                Text("Press a key again on an already-tagged selection to clear it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Finder Colors") {
                ForEach(ShortcutAction.colorActions) { ShortcutRow(action: $0) }
            }
            Section {
                HStack {
                    Image(systemName: "sidebar.right").foregroundStyle(.secondary).frame(width: 14)
                    Text("Toggle side panes")
                    Spacer()
                    Button("Tab") { env.shortcuts.setPaneToggleToTab() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(env.shortcuts.paneToggleKey == "tab" ? Color.secondary : Color.accentColor)
                    TextField("", text: Binding(
                        get: { env.shortcuts.paneToggleDisplay },
                        set: { newValue in
                            if let ch = newValue.last, ch.isLetter || ch.isNumber {
                                env.shortcuts.setPaneToggleKey(String(ch))
                            }
                        }))
                    .frame(width: 48).multilineTextAlignment(.center).textFieldStyle(.roundedBorder)
                }
            } header: {
                Text("View")
            } footer: {
                Text("Collapses the Reclaimable, Action plan and Inspector panes to enlarge the browser (Modern skin). Type a letter to rebind, or click Tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Reset to Defaults") { env.shortcuts.resetToDefaults() }
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutRow: View {
    @Environment(AppEnvironment.self) private var env
    let action: ShortcutAction

    var body: some View {
        HStack {
            indicator
            Text(action.title)
            Spacer()
            TextField("", text: Binding(
                get: { env.shortcuts.key(for: action).uppercased() },
                set: { newValue in
                    if let ch = newValue.last { env.shortcuts.setKey(String(ch), for: action) }
                }))
            .frame(width: 38)
            .multilineTextAlignment(.center)
            .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder private var indicator: some View {
        if let color = action.color, color != .none {
            Circle().fill(color.swiftUIColor).frame(width: 12, height: 12)
        } else if let tag = action.decision, tag != .none {
            Image(systemName: tag.symbol).foregroundStyle(tag.swiftUIColor).frame(width: 14)
        } else {
            Image(systemName: "slash.circle").foregroundStyle(.secondary).frame(width: 14)
        }
    }
}
