import SwiftUI
import DiskGalleryCore

struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            ShortcutSettings()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 480, height: 420)
    }
}

struct AppearanceSettings: View {
    @Environment(AppEnvironment.self) private var env

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 12)]

    var body: some View {
        @Bindable var theme = env.theme
        Form {
            Section("Mode") {
                Picker("Appearance", selection: $theme.mode) {
                    ForEach(AppearanceMode.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Section("Theme") {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(AppTheme.allCases) { option in
                        Button { env.theme.theme = option } label: {
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(option.accent)
                                    .frame(width: 36, height: 36)
                                    .overlay(Circle().strokeBorder(env.theme.theme == option ? Color.primary : .clear, lineWidth: 2.5))
                                Text(option.name).font(.caption)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .tint(env.theme.theme.accent)
    }
}

struct ShortcutSettings: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Form {
            Section("Decisions") {
                ForEach(ShortcutAction.decisionActions) { ShortcutRow(action: $0) }
            }
            Section("Finder colors") {
                ForEach(ShortcutAction.colorActions) { ShortcutRow(action: $0) }
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
