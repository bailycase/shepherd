import SwiftUI

/// Project Browser's text-only delete actions and its two confirmation buttons.
public struct NWSettingsActionStyle: ButtonStyle {
    public enum Kind { case quietDanger, cancel, confirm }
    let kind: Kind

    public init(_ kind: Kind) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        NWSettingsAction(configuration: configuration, kind: kind)
    }
}

private struct NWSettingsAction: View {
    let configuration: ButtonStyleConfiguration
    let kind: NWSettingsActionStyle.Kind
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let quiet = kind == .quietDanger
        let radius = quiet ? NW.Radius.s : NWSettingsControlMetrics.radius
        let fill: Color = switch kind {
        case .quietDanger: hovering && enabled ? .nw.failedTint : .clear
        case .cancel: hovering && enabled ? .nw.bgHover : .nw.bgRaised
        case .confirm: hovering && enabled ? .nw.projectCookieConfirmHover : .nw.projectCookieConfirm
        }
        configuration.label
            .font(.nwSans(NWSettingsNavMetrics.subTextSize, .medium))
            .foregroundStyle(kind == .quietDanger ? Color.nw.projectCookieDanger : kind == .confirm ? (hovering && enabled ? Color.nw.projectCookieConfirmTextHover : Color.nw.textOnRunning) : Color.nw.textPrimary)
            .padding(.horizontal, quiet ? NWSettingsControlMetrics.fieldPadding : NW.Space.l + (kind == .cancel ? NWSettingsNavMetrics.borderWidth : 0))
            .frame(minHeight: quiet ? NW.Height.controlM : NWSettingsControlMetrics.controlHeight)
            .background(fill, in: RoundedRectangle(cornerRadius: radius))
            .nwBorder(kind == .cancel ? Color.nw.lineStrong : .clear, radius: radius, width: NWSettingsNavMetrics.borderWidth)
            .contentShape(RoundedRectangle(cornerRadius: radius))
            .nwEnabledOpacity(enabled)
            .onHover { hovering = $0 }
            .nwFocusRing(radius: radius, color: .nw.running)
    }
}
