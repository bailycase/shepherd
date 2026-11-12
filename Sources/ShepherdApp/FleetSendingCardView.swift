import SwiftUI
import ShepherdRemote
import ShepherdUI

/// "Sending with uncommitted changes" (FleetStates): work on its way to another Mac with the checkout's edits and files. The Fleet page's
/// Dispatches row draws it while a dispatch is `preparing`; the thread that sent the work draws the same view (slice 4d).
struct FleetSendingCardView: View, Equatable {
    let card: FleetSendingCard

    nonisolated static func == (a: FleetSendingCardView, b: FleetSendingCardView) -> Bool { a.card == b.card }

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.l) {
            HStack(spacing: SH.Space.m) {
                Text(card.title).font(.sh(.headline)).foregroundStyle(sh.textPrimary).lineLimit(1)
                Text(card.host)
                    .font(.sh(.micro, weight: .regular))
                    .foregroundStyle(sh.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, SH.Space.xs)
                    .frame(height: AppLayout.fleetTagHeight)
                    .shBorder(sh.lineStrong, radius: SH.Radius.xs)
                Spacer(minLength: SH.Space.m)
                FleetPill(text: card.state, dot: sh.running, text: sh.running, fill: sh.runningTint)
            }
            Text(card.summary)
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(sh.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: SH.Space.m) {
                FleetGauge(fraction: card.fraction ?? 0, color: sh.running, height: AppLayout.fleetSendBarHeight)
                Text(card.progress)
                    .font(.sh(.mono))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if let warning = card.warning {
                Text(warning).font(.sh(.caption, weight: .regular)).foregroundStyle(sh.lanternText)
            }
        }
        .padding(SH.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: SH.Radius.l, fill: sh.bgRaised, line: sh.lineSubtle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibilityLabel)
        .accessibilityValue(card.warning ?? "")
    }
}
