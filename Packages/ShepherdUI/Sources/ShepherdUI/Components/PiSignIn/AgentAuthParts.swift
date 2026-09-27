import SwiftUI

// An agent's thread while the first launch's copy holds it, and once it can't start because it
// isn't signed in (PiAuthStates, PiImportProgress, AgentNotSignedIn).

/// "Waiting to continue" (`AgentWaitingLine(restoredAt:)`): one static line at the end of a
/// restored agent's thread while the first launch's copy holds it.
public struct NWAgentWaitingLine: View, Equatable {
    let message: String
    let trailing: String?

    public init(message: String, trailing: String? = nil) {
        self.message = message
        self.trailing = trailing
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: 10) {
            Image(systemName: "clock")
                .font(.nwSans(14))
                .foregroundStyle(nw.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text("Waiting to continue").font(.nwSans(13, .medium)).foregroundStyle(nw.textPrimary)
                Text(message)
                    .font(.nwSans(NWPiSignInMetrics.statusSize))
                    .foregroundStyle(nw.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let trailing {
                Text(trailing).font(.nwMono(NWPiSignInMetrics.timeSize)).foregroundStyle(nw.textTertiary).fixedSize()
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(nw.bgSunken, in: RoundedRectangle(cornerRadius: NWPiSignInMetrics.cardRadius))
        .nwBorder(nw.lineSubtle, radius: NWPiSignInMetrics.cardRadius)
        .accessibilityElement(children: .combine)
    }
}

/// "Not signed in to Anthropic" (`AgentNotSignedInCard(provider:)`): a lantern card at the end of
/// the thread with Sign in to <provider> and Use another model.
public struct NWAgentNotSignedInCard<Models: View>: View {
    let provider: String
    let model: String?
    let reason: String
    let time: String?
    let signIn: () -> Void
    let models: Models?

    /// `reason` follows "This agent uses `model`." ("Anthropic’s sign-in was skipped when your pi
    /// came over, so the agent is waiting for you. Your message is kept."). `models` is Use another
    /// model's menu; nil leaves the button out.
    public init(provider: String, model: String?, reason: String, time: String? = nil, signIn: @escaping () -> Void,
                @ViewBuilder models: () -> Models) {
        self.provider = provider
        self.model = model
        self.reason = reason
        self.time = time
        self.signIn = signIn
        self.models = models()
    }

    public var body: some View {
        let nw = Color.nw
        let M = NWPiSignInMetrics.self
        VStack(alignment: .leading, spacing: NW.Space.l) {
            HStack(alignment: .top, spacing: NW.Space.l) {
                Image(systemName: "key")
                    .font(.nwSans(M.cardGlyph - 3, .medium))
                    .foregroundStyle(nw.lanternText)
                    .frame(width: M.cardTile, height: M.cardTile)
                    .background(nw.lanternTint, in: RoundedRectangle(cornerRadius: M.cardRadius))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: M.lineGap) {
                    Text("Not signed in to \(provider)")
                        .font(.nwSans(M.cardTitleSize, .semibold))
                        .foregroundStyle(nw.textPrimary)
                    message
                        .nwText(size: 13, lineHeight: 1.5)
                        .foregroundStyle(nw.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.top, NW.Space.xxs)
                .frame(maxWidth: .infinity, alignment: .leading)
                if let time {
                    Text(time).font(.nwMono(M.timeSize)).foregroundStyle(nw.textTertiary).fixedSize()
                }
            }
            HStack(spacing: NW.Space.m) {
                Button(action: signIn) { Label("Sign in to \(provider)", systemImage: "key") }
                    .buttonStyle(.nw(.primary, size: .s))
                if let models {
                    Menu { models } label: {
                        Label("Use another model", systemImage: "arrow.triangle.swap")
                            .font(.nwSans(12, .medium))
                            .foregroundStyle(nw.textSecondary)
                            .padding(.horizontal, NW.Space.m)
                            .frame(height: NW.Height.controlS)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .padding(.leading, M.cardTile + NW.Space.l)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, NW.Space.xl)
        .background(nw.lantern.opacity(M.cardFillOpacity), in: RoundedRectangle(cornerRadius: M.cardRadius))
        .nwBorder(nw.lantern.opacity(M.cardLineOpacity), radius: M.cardRadius)
    }

    private var message: Text {
        guard let model else { return Text(reason) }
        return Text("This agent uses ") + Text(model).font(.nwMono(12.5)).foregroundColor(Color.nw.textPrimary) + Text(". ") + Text(reason)
    }
}

extension NWAgentNotSignedInCard where Models == EmptyView {
    /// With no other model to offer.
    public init(provider: String, model: String?, reason: String, time: String? = nil, signIn: @escaping () -> Void) {
        self.provider = provider
        self.model = model
        self.reason = reason
        self.time = time
        self.signIn = signIn
        self.models = nil
    }
}
