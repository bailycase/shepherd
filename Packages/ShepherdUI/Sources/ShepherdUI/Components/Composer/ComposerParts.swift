import SwiftUI

/// A ghost chip in the composer's action row (model, thinking, commands): 32pt, hover and
/// active fill `bgHover`.
public struct NWComposerChipStyle: ButtonStyle {
    let active: Bool

    public init(active: Bool = false) { self.active = active }

    public func makeBody(configuration: Configuration) -> some View {
        NWComposerChip(configuration: configuration, active: active)
    }
}

extension ButtonStyle where Self == NWComposerChipStyle {
    public static func nwComposerChip(active: Bool = false) -> NWComposerChipStyle { NWComposerChipStyle(active: active) }
}

private struct NWComposerChip: View {
    let configuration: ButtonStyleConfiguration
    let active: Bool
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.nw(.caption))
            .foregroundStyle(.nw.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: NW.Height.controlL)
            .background(active || hovering || configuration.isPressed ? Color.nw.bgHover : .clear,
                        in: RoundedRectangle(cornerRadius: NW.Radius.s))
            .contentShape(RoundedRectangle(cornerRadius: NW.Radius.s))
            .onHover { hovering = $0 }
            .nwFocusRing(radius: NW.Radius.s)
    }
}

/// The down chevron chips and popups use.
public struct NWChipChevron: View {
    public init() {}

    public var body: some View {
        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.nw.textTertiary)
    }
}

/// The composer's single 32pt action: Send (arrow on the lantern fill) or Stop (square on
/// `failed`) while a turn runs.
public struct NWComposerActionButton: View {
    public enum Mode: Sendable { case send, stop }

    let mode: Mode
    let enabled: Bool
    let action: () -> Void

    public init(_ mode: Mode, enabled: Bool = true, action: @escaping () -> Void) {
        self.mode = mode
        self.enabled = enabled
        self.action = action
    }

    public var body: some View {
        let nw = Color.nw
        Button(action: action) {
            Group {
                switch mode {
                case .send:
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold)).foregroundStyle(nw.textOnLantern)
                case .stop:
                    Image(systemName: "stop.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(nw.textOnFailed)
                }
            }
            .frame(width: NW.Height.controlL, height: NW.Height.controlL)
            .background(mode == .send ? nw.lantern : nw.failed, in: RoundedRectangle(cornerRadius: NW.Radius.m))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: NW.Radius.m))
            .nwFocusRing(radius: NW.Radius.m)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(mode == .send ? "Send" : "Stop")
    }
}
