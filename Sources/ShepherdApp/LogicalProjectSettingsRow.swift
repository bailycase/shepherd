import SwiftUI
import ShepherdUI

/// The Project settings card (ProjectLead-Settings*): 1pt `lineStrong` line, radius 12, `bgRaised`, rows inside the line and
/// divided by 1pt `lineSubtle`. A row is 52pt at the least counting its own divider. The lines are the board's 1pt, not a device
/// hairline.
struct ProjectSettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        let M = SHProjectSettingsMetrics.self
        let shape = RoundedRectangle(cornerRadius: SH.Radius.l)
        VStack(spacing: 0) {
            Group(subviews: content()) { subviews in
                ForEach(subviews) { subview in
                    let first = subview.id == subviews.first?.id
                    if !first { SHHairline(width: M.line) }
                    subview.frame(minHeight: first ? M.rowMinHeight : M.rowMinHeight - M.line)
                }
            }
        }
        .padding(M.line)
        .background(Color.sh.bgRaised, in: shape)
        .clipShape(shape)
        .shBorder(Color.sh.lineStrong, radius: SH.Radius.l, width: M.line)
    }
}

/// A row of a Project settings card: a 12.5/500 title over a 11.5 `textTertiary` description, 12pt before the control.
struct ProjectSettingsRow<Control: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: SH.Space.l) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(title).font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary)
                if let subtitle {
                    SHMarkupText(subtitle, size: SHTextStyle.caption.size, lineHeight: SHCardRowMetrics.settingsDescriptionLineHeight)
                        .foregroundStyle(Color.sh.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .modifier(ProjectSettingsRowFrame())
        .accessibilityElement(children: .contain)
    }
}

/// The row's own padding (12 in, 8 above and below), for rows that bring their own content.
struct ProjectSettingsRowFrame: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, SH.Space.l)
            .padding(.vertical, SH.Space.m)
    }
}

/// A button of a Project settings row: the shared 28pt button with the board's 1pt line counted in its width (text + 22).
/// `danger` is Delete…: `failed` text on the card's fill, its line `failed` at 30%.
struct ProjectSettingsButton: View {
    let title: String
    var kind: SHButtonStyle.Kind = .secondary
    var danger = false
    let action: () -> Void

    var body: some View {
        let label = Text(title).padding(.horizontal, SHProjectSettingsMetrics.line)
        if danger {
            Button(action: action) { label }.buttonStyle(SHProjectSettingsDangerStyle())
        } else {
            Button(action: action) { label }.buttonStyle(.sh(kind))
        }
    }
}
