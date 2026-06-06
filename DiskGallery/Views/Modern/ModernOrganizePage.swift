import SwiftUI
import DiskGalleryCore

/// Modern Organize workspace: the cross-drive, non-destructive transfer plan shown as a
/// numbered report (left), totals + export (bottom-left), and a graphical action canvas
/// (right), over the permanent OLED hero. Destinations are auto-suggested; each Move/Backup
/// row can be re-pointed, which re-plans instantly (the planner is pure).
struct ModernOrganizePage: View {
    @Environment(AppEnvironment.self) private var env

    @State private var drives: [PlanDrive] = []
    @State private var items: [PlanItemSource] = []
    @State private var overrides: [String: String] = [:]
    @State private var loaded = false

    private var plan: OrganizationPlan {
        OrganizationPlanner.plan(drives: drives, items: items, overrides: overrides)
    }

    var body: some View {
        let plan = self.plan
        ModernPageScaffold(leadingIcon: "wand.and.stars",
                           crumbs: ["Organize", crumb(for: plan)],
                           oledPlan: .init(plan),
                           oledLayoutOverride: .actionDetail) {
            if loaded && plan.steps.isEmpty {
                emptyState
            } else {
                ModernBento {
                    OrganizeReportCard(plan: plan, overrides: $overrides)
                } bottomLeft: {
                    OrganizeSummaryTile(plan: plan)
                } right: {
                    OrganizeCanvasCard(plan: plan)
                }
            }
        }
        .task(id: env.dataVersion) {
            (drives, items) = await env.organizationPlanInputs()
            // Drop overrides whose item no longer exists (re-scan, untag, etc.).
            let live = Set(items.map(\.id))
            overrides = overrides.filter { live.contains($0.key) }
            loaded = true
        }
    }

    private func crumb(for plan: OrganizationPlan) -> String {
        plan.isFeasible ? "\(plan.steps.count) steps" : "\(plan.unassigned.count) won’t fit"
    }

    private var emptyState: some View {
        GlassCard {
            ContentUnavailableView {
                Label("Nothing to organize", systemImage: "wand.and.stars")
            } description: {
                Text("Tag items Move, Backup, or Delete across your drives and a step-by-step transfer plan appears here — with destinations chosen for you.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Report card (numbered run order + destination overrides)

private struct OrganizeReportCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    let plan: OrganizationPlan
    @Binding var overrides: [String: String]
    private var accent: Color { env.theme.accent.palette.accent }

    var body: some View {
        GlassCard {
            VStack(spacing: 0) {
                ModernCardHeader(systemImage: "list.number", title: "Organization Plan",
                                 meta: meta, accent: accent)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(plan.steps) { step in
                            OrganizeStepRow(step: step, overrides: $overrides)
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var meta: String {
        let ops = plan.steps.filter { $0.operation != .verify }.count
        let time = plan.estTotalDuration > 0 ? " · ~\(Format.duration(plan.estTotalDuration))" : ""
        return "\(ops) operation\(ops == 1 ? "" : "s")\(time)"
    }
}

private struct OrganizeStepRow: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    let step: PlanStep
    @Binding var overrides: [String: String]
    private var accent: Color { env.theme.accent.palette.accent }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            numberBadge
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(tint)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DGToken.ink(scheme)).lineLimit(1)
                routeLine
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                if step.operation != .verify, step.bytes > 0 {
                    Text(Format.bytes(step.bytes))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(DGToken.ink2(scheme))
                }
                statusChip
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(DGToken.glass2(scheme).opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var numberBadge: some View {
        Text("\(step.orderIndex)")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(accent)
            .frame(width: 22, height: 22)
            .background(accent.opacity(0.16), in: Circle())
    }

    @ViewBuilder private var routeLine: some View {
        switch step.operation {
        case .verify:
            EmptyView()
        case .delete:
            Text("\(step.sourceDriveName ?? "?") · frees space")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(DGToken.ink3(scheme)).lineLimit(1)
        case .move, .copy:
            HStack(spacing: 6) {
                Text(step.sourceDriveName ?? "?")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(DGToken.ink3(scheme))
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(accent)
                destinationMenu
            }
        }
    }

    private var destinationMenu: some View {
        Menu {
            Button("Auto") { overrides[step.id] = nil }
            Divider()
            ForEach(env.destinationChoices(excluding: step.sourceDriveKey ?? "")) { drive in
                let key = drive.uuid ?? drive.name
                Button {
                    overrides[step.id] = key
                } label: {
                    if (overrides[step.id] ?? step.destinationDriveKey) == key {
                        Label(drive.name, systemImage: "checkmark")
                    } else {
                        Text(drive.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(step.destinationDriveName ?? "choose")
                    .font(.system(size: 10, weight: step.isOverride ? .bold : .regular, design: .monospaced))
                    .foregroundStyle(step.destinationDriveName == nil ? DGToken.bad : (step.isOverride ? accent : DGToken.ink2(scheme)))
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                    .foregroundStyle(DGToken.ink3(scheme))
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    @ViewBuilder private var statusChip: some View {
        switch step.feasibility {
        case .ok:           EmptyView()
        case .needsConnect: chip("CONNECT", DGToken.warn)
        case .overflow:     chip("WON’T FIT", DGToken.bad)
        case .unassigned:   chip("NO DRIVE", DGToken.bad)
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 8, weight: .bold, design: .monospaced)).tracking(0.6)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .foregroundStyle(color)
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
        case .verify: DGToken.ink3(scheme)
        case .delete: Tag.delete.modernColor
        case .move:   Tag.move.modernColor
        case .copy:   Tag.backup.modernColor
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
}

// MARK: - Summary tile (totals + export)

private struct OrganizeSummaryTile: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    let plan: OrganizationPlan
    private var accent: Color { env.theme.accent.palette.accent }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 0) {
                Text("TRANSFER SUMMARY")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced)).tracking(1.8)
                    .foregroundStyle(DGToken.ink3(scheme))
                BigNum(bytes: plan.totalBytesToMove + plan.totalBytesToCopy, tint: accent)
                    .padding(.top, 8)
                HStack(spacing: 6) {
                    Text("\(operationCount) job\(operationCount == 1 ? "" : "s")")
                    if plan.estTotalDuration > 0 { Text("· est. \(Format.duration(plan.estTotalDuration))") }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12)).foregroundStyle(DGToken.ink2(scheme)).padding(.top, 6)

                Spacer(minLength: 10)

                feasibilityNote.padding(.bottom, 10)
                CTAButton(title: "Export plan", systemImage: "square.and.arrow.up", disabled: plan.steps.isEmpty) {
                    env.exportOrganizationReport(plan)
                }
            }
            .padding(16)
        }
    }

    private var operationCount: Int { plan.steps.filter { $0.operation != .verify }.count }

    @ViewBuilder private var feasibilityNote: some View {
        if !plan.isFeasible {
            ModernNote(text: "\(plan.unassigned.count) item\(plan.unassigned.count == 1 ? "" : "s") won’t fit — free space or add a drive",
                       systemImage: "exclamationmark.triangle", warn: true)
        } else if !plan.drivesToConnect.isEmpty {
            ModernNote(text: "Connect to run: \(plan.drivesToConnect.joined(separator: ", "))",
                       systemImage: "powerplug", warn: true)
        } else {
            ModernNote(text: "Non-destructive — your playbook, nothing is moved",
                       systemImage: "checkmark.shield")
        }
    }
}

// MARK: - Action canvas (drives as nodes, transfers as flow arrows, before → after)

private struct OrganizeCanvasCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    let plan: OrganizationPlan
    private var accent: Color { env.theme.accent.palette.accent }

    private let gutter: CGFloat = 56
    private let trailing: CGFloat = 14
    private let vInset: CGFloat = 8

    /// Move/Backup steps that have a destination — the flow edges.
    private var transfers: [PlanStep] {
        plan.steps.filter { ($0.operation == .move || $0.operation == .copy) && $0.destinationDriveKey != nil }
    }
    private var indexByKey: [String: Int] {
        Dictionary(uniqueKeysWithValues: plan.projections.enumerated().map { ($1.id, $0) })
    }
    private var destinationKeys: Set<String> { Set(transfers.compactMap(\.destinationDriveKey)) }

    var body: some View {
        GlassCard {
            VStack(spacing: 0) {
                ModernCardHeader(systemImage: "externaldrive.connected.to.line.below",
                                 title: "Action Canvas", meta: "before → after", accent: accent)
                GeometryReader { geo in
                    let rowH: CGFloat = 104
                    let total = rowH * CGFloat(plan.projections.count)
                    let nodeWidth = geo.size.width - gutter - trailing
                    ScrollView(.vertical, showsIndicators: true) {
                        ZStack(alignment: .topLeading) {
                            edges(rowH: rowH)
                            ForEach(Array(plan.projections.enumerated()), id: \.element.id) { index, projection in
                                nodeCard(projection)
                                    .frame(width: nodeWidth, height: rowH - vInset * 2)
                                    .offset(x: gutter, y: CGFloat(index) * rowH + vInset)
                            }
                        }
                        .frame(width: geo.size.width, height: max(total, geo.size.height), alignment: .topLeading)
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    /// Straight (orthogonal) flow arrows: a stub out of the source node, a vertical run
    /// down the gutter lane, and a stub into the destination node ending in an arrowhead.
    private func edges(rowH: CGFloat) -> some View {
        Canvas { context, _ in
            func centerY(_ index: Int) -> CGFloat { CGFloat(index) * rowH + rowH / 2 }
            let laneX = max(10, gutter - 34)
            let arrowLen: CGFloat = 6
            let arrowHalf: CGFloat = 3.5
            for step in transfers {
                guard let sourceKey = step.sourceDriveKey,
                      let from = indexByKey[sourceKey],
                      let destKey = step.destinationDriveKey,
                      let to = indexByKey[destKey] else { continue }
                let y0 = centerY(from), y1 = centerY(to)
                let width = edgeWidth(step.bytes)
                let tint = step.feasibility == .overflow ? DGToken.bad : accent
                var path = Path()
                path.move(to: CGPoint(x: gutter, y: y0))            // out of the source node
                path.addLine(to: CGPoint(x: laneX, y: y0))
                path.addLine(to: CGPoint(x: laneX, y: y1))          // straight vertical run
                path.addLine(to: CGPoint(x: gutter - arrowLen, y: y1))  // stop at the arrowhead base
                context.stroke(path, with: .color(tint.opacity(0.9)),
                               style: StrokeStyle(lineWidth: width, lineCap: .butt, lineJoin: .miter))
                // Arrowhead: tip flush at the node edge, base centered on the line.
                var head = Path()
                head.move(to: CGPoint(x: gutter, y: y1))
                head.addLine(to: CGPoint(x: gutter - arrowLen, y: y1 - arrowHalf))
                head.addLine(to: CGPoint(x: gutter - arrowLen, y: y1 + arrowHalf))
                head.closeSubpath()
                context.fill(head, with: .color(tint))
            }
        }
    }

    private func edgeWidth(_ bytes: Int64) -> CGFloat {
        let gb = max(1.0, Double(bytes) / 1_000_000_000)
        return CGFloat(min(2.4, 1.1 + log10(gb + 1) * 0.6))
    }

    private func nodeCard(_ projection: CapacityProjection) -> some View {
        let isDestination = destinationKeys.contains(projection.id)
        let border: Color = projection.willOverflow ? DGToken.bad
            : (isDestination ? accent.opacity(0.45) : DGToken.hair(scheme))
        return OrganizeProjectionRow(projection: projection)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(DGToken.glass2(scheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(border, lineWidth: 1))
    }
}

private struct OrganizeProjectionRow: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    let projection: CapacityProjection
    private var accent: Color { env.theme.accent.palette.accent }
    private var changed: Bool { abs(projection.projectedFraction - projection.currentFraction) > 0.0001 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(projection.driveName).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DGToken.ink(scheme)).lineLimit(1)
                Spacer(minLength: 6)
                if changed {
                    Text("\(Format.percent(projection.currentFraction)) → ")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(DGToken.ink3(scheme))
                    + Text(Format.percent(projection.projectedFraction))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(projection.willOverflow ? DGToken.bad : accent)
                } else {
                    Text(Format.percent(projection.currentFraction))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(DGToken.ink3(scheme))
                }
            }
            bar
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let cur = max(0, min(1, projection.currentFraction))
            let proj = max(0, min(1, projection.projectedFraction))
            ZStack(alignment: .leading) {
                Capsule().fill(DGToken.inset(scheme))                       // empty track
                if proj < cur {                                            // freeing: show old extent behind
                    Capsule().fill(DGToken.ink4(scheme)).frame(width: width * cur)
                }
                Capsule().fill(projection.willOverflow ? AnyShapeStyle(DGToken.bad)
                               : AnyShapeStyle(LinearGradient(colors: [env.theme.accent.palette.accent2, accent],
                                                              startPoint: .leading, endPoint: .trailing)))
                    .frame(width: width * proj)                            // projected usage
                if changed {                                              // "before" marker
                    Rectangle().fill(DGToken.ink(scheme).opacity(0.6))
                        .frame(width: 1.5, height: 12).offset(x: width * cur - 0.75)
                }
            }
        }
        .frame(height: 12)
        .clipShape(Capsule())
    }
}

// MARK: - OLED action summary

extension OLEDDisplayView.PlanSummary {
    init(_ plan: OrganizationPlan) {
        self.init(
            operationCount: plan.steps.filter { $0.operation != .verify }.count,
            bytesToMove: plan.totalBytesToMove,
            bytesToCopy: plan.totalBytesToCopy,
            bytesToFree: plan.totalBytesToFree,
            estDuration: plan.estTotalDuration,
            isFeasible: plan.isFeasible,
            drivesToConnect: plan.drivesToConnect)
    }
}
