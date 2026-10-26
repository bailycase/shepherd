import SwiftUI

/// Project Browser's text-only delete actions and its two confirmation buttons.
public struct SHSettingsActionStyle: ButtonStyle {
    public enum Kind { case quietDanger, cancel, confirm }
    let kind: Kind

    public init(_ kind: Kind) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        SHSettingsAction(configuration: configuration, kind: kind)
    }
}

private struct SHSettingsAction: View {
    let configuration: ButtonStyleConfiguration
    let kind: SHSettingsActionStyle.Kind
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let quiet = kind == .quietDanger
        let radius = quiet ? SH.Radius.s : SHSettingsControlMetrics.radius
        let fill: Color = switch kind {
        case .quietDanger: hovering && enabled ? .sh.failedTint : .clear
        case .cancel: hovering && enabled ? .sh.bgHover : .sh.bgRaised
        case .confirm: hovering && enabled ? .sh.projectCookieConfirmHover : .sh.projectCookieConfirm
        }
        configuration.label
            .font(.shSans(SHSettingsNavMetrics.subTextSize, .medium))
            .foregroundStyle(kind == .quietDanger ? Color.sh.projectCookieDanger : kind == .confirm ? (hovering && enabled ? Color.sh.projectCookieConfirmTextHover : Color.sh.textOnRunning) : Color.sh.textPrimary)
            .padding(.horizontal, quiet ? SHSettingsControlMetrics.fieldPadding : SH.Space.l + (kind == .cancel ? SHSettingsNavMetrics.borderWidth : 0))
            .frame(minHeight: quiet ? SH.Height.controlM : SHSettingsControlMetrics.controlHeight)
            .background(fill, in: RoundedRectangle(cornerRadius: radius))
            .shBorder(kind == .cancel ? Color.sh.lineStrong : .clear, radius: radius, width: SHSettingsNavMetrics.borderWidth)
            .contentShape(RoundedRectangle(cornerRadius: radius))
            .shEnabledOpacity(enabled)
            .onHover { hovering = $0 }
            .shFocusRing(radius: radius, color: .sh.running)
    }
}
