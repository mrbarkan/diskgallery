import SwiftUI
import DiskGalleryCore

/// Classic (native) Organize view: the cross-drive, non-destructive transfer plan as a
/// numbered run-order list. Backed by the same `OrganizationPlanner` as the Modern page.
struct OrganizeView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var plan: OrganizationPlan = .empty
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded && plan.steps.isEmpty {
                ContentUnavailableView(
                    "Nothing to organize",
                    systemImage: "wand.and.stars",
                    description: Text("Tag items Move, Backup, or Delete across your drives and a step-by-step transfer plan appears here."))
            } else {
                List {
                    Section { summary } header: { Text("Plan") }
                    Section {
                        ForEach(plan.steps) { OrganizeStepRow(step: $0) }
                    } header: { Text("Run order") }
                    if !plan.unassigned.isEmpty {
                        Section {
                            ForEach(plan.unassigned) { item in
                                Label("\(item.name) — \(Format.bytes(item.bytes)) won’t fit anywhere",
                                      systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                        } header: { Text("Couldn’t place — free space or add a drive") }
                    }
                }
            }
        }
        .navigationTitle("Organize")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Export Plan…") { env.exportOrganizationReport(plan) }
                    Button("Copy Plan") { env.copyOrganizationReport(plan) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(plan.steps.isEmpty)
            }
        }
        .task(id: env.dataVersion) {
            plan = await env.organizationPlan()
            loaded = true
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                stat("To move", Format.bytes(plan.totalBytesToMove))
                stat("To back up", Format.bytes(plan.totalBytesToCopy))
                stat("Frees", Format.bytes(plan.totalBytesToFree))
                if plan.estTotalDuration > 0 { stat("Est. time", Format.duration(plan.estTotalDuration)) }
            }
            if !plan.drivesToConnect.isEmpty {
                Label("Connect to run: \(plan.drivesToConnect.joined(separator: ", "))", systemImage: "powerplug")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Label("Non-destructive — DiskGallery never moves files. This is your playbook.",
                  systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// One run-order row in the Classic Organize list.
private struct OrganizeStepRow: View {
    let step: PlanStep

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(step.orderIndex)")
                .font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)
            Image(systemName: icon).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium).lineLimit(1)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(subtitleColor).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if step.operation != .verify, step.bytes > 0 {
                Text(Format.bytes(step.bytes))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch step.operation {
        case .verify: "checkmark.seal"
        case .delete: "trash"
        case .move:   "arrow.right.circle"
        case .copy:   "shippingbox"
        }
    }

    private var tint: Color {
        switch step.operation {
        case .verify: .secondary
        case .delete: .red
        case .move:   .blue
        case .copy:   .purple
        }
    }

    private var title: String {
        switch step.operation {
        case .verify: step.name
        case .delete: "Delete \(step.name)"
        case .move:   "Move \(step.name)"
        case .copy:   "Back up \(step.name)"
        }
    }

    private var subtitle: String? {
        switch step.operation {
        case .verify:
            return nil
        case .delete:
            return "\(step.sourceDriveName ?? "?") · frees space"
        case .move, .copy:
            let base = "\(step.sourceDriveName ?? "?") → \(step.destinationDriveName ?? "unassigned")"
            switch step.feasibility {
            case .needsConnect: return base + " · connect \(step.destinationDriveName ?? "drive")"
            case .overflow:     return base + " · exceeds capacity"
            case .unassigned:   return base + " · no destination"
            case .ok:           return base
            }
        }
    }

    private var subtitleColor: Color {
        step.feasibility == .ok || step.operation == .verify || step.operation == .delete ? .secondary : .orange
    }
}
