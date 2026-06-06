import SwiftUI
import DiskGalleryCore

/// A thin glass path/breadcrumb bar that sits directly above the browser (Modern skin).
/// The drive name is the first crumb; earlier crumbs are tappable when `onCrumb` is set
/// (the volume browser), or static title crumbs on the library pages.
struct ModernPathBar: View {
    @Environment(\.colorScheme) private var scheme
    var leadingIcon: String = "externaldrive"
    let crumbs: [String]
    var onCrumb: ((Int) -> Void)? = nil

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: leadingIcon).font(.system(size: 13)).foregroundStyle(DGToken.ink3(scheme))
            ForEach(Array(crumbs.enumerated()), id: \.offset) { i, seg in
                if i > 0 { Text("/").font(.system(size: 12)).foregroundStyle(DGToken.ink4(scheme)) }
                let isCurrent = (i == crumbs.count - 1)
                if let onCrumb, !isCurrent {
                    Button { onCrumb(i) } label: { crumbText(seg, current: false) }
                        .buttonStyle(.plain)
                } else {
                    crumbText(seg, current: isCurrent)
                }
            }
            Spacer(minLength: 8)
        }
        .lineLimit(1)
        .padding(.horizontal, 4).frame(height: 24, alignment: .leading)
    }

    private func crumbText(_ seg: String, current: Bool) -> some View {
        Text(seg).font(.system(size: 13, weight: current ? .semibold : .regular))
            .foregroundStyle(current ? DGToken.ink(scheme) : DGToken.ink3(scheme))
            .lineLimit(1)
    }
}
