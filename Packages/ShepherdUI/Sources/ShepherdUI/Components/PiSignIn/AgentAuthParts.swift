import SwiftUI

// An agent's thread while the first launch's copy holds it, and once it can't start because it
// isn't signed in (PiAuthStates, PiImportProgress, AgentNotSignedIn).

/// "Waiting to continue" (`AgentWaitingLine(restoredAt:)`): one static line at the end of a
/// restored agent's thread while the first launch's copy holds it.
public struct SHAgentWaitingLine: View, Equatable {
    let message: String
    let trailing: String?

    public init(message: String, trailing: String? = nil) {
        self.message = message
        self.trailing = trailing
    }

    public var body: some View {
        let sh = Color.sh
        HStack(spacing: 10) {
            Image(systemName: "clock")
                .font(.shSans(14))
                .foregroundStyle(sh.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text("Waiting to continue").font(.shSans(13, .medium)).foregroundStyle(sh.textPrimary)
                Text(message)
                    .font(.shSans(SHPiSignInMetrics.statusSize))
                    .foregroundStyle(sh.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let trailing {
                Text(trailing).font(.shMono(SHPiSignInMetrics.timeSize)).foregroundStyle(sh.textTertiary).fixedSize()
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(sh.bgSunken, in: RoundedRectangle(cornerRadius: SHPiSignInMetrics.cardRadius))
        .shBorder(sh.lineSubtle, radius: SHPiSignInMetrics.cardRadius)
        .accessibilityElement(children: .combine)
    }
}

/// "Not signed in to Anthropic" (`AgentNotSignedInCard(provider:)`): a raised card at the end of
/// the thread with Use another model and Sign in to <provider> as words.
public struct SHAgentNotSignedInCard<Models: View>: View {
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
        let sh = Color.sh
        let M = SHPiSignInMetrics.self
        // The board's card (`gss-card`): a raised, lifted card at radius 14, 14 over and 16 in; the title, a line under it, and the
        // two actions as words at the right.
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: SH.Space.l) {
                Text("Not signed in to \(provider)")
                    .font(.shSans(M.noticeTitleSize, .semibold))
                    .foregroundStyle(sh.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let time {
                    Text(time).font(.shMono(M.timeSize)).foregroundStyle(sh.textTertiary).fixedSize()
                }
            }
            message
                .shText(size: M.noticeTitleSize, lineHeight: M.noticeLine)
                .foregroundStyle(sh.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, M.noticeGap)
            HStack(spacing: M.footerGap) {
                Spacer(minLength: 0)
                if let models {
                    Menu { models } label: {
                        Text("Use another model")
                            .font(.shSans(M.noticeTitleSize))
                            .foregroundStyle(sh.textSecondary)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                Button(action: signIn) {
                    Text("Sign in to \(provider)").font(.shSans(M.noticeTitleSize, .medium)).foregroundStyle(sh.textPrimary)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, M.noticeActionsTop)
        }
        .padding(.vertical, M.noticeVertical)
        .padding(.horizontal, M.noticeHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: M.noticeRadius, lift: true)
        .accessibilityElement(children: .contain)
    }

    private var message: Text {
        guard let model else { return Text(reason) }
        return Text("This agent uses ") + Text(model).font(.shMono(SHPiSignInMetrics.noticeMonoSize)).foregroundColor(Color.sh.textPrimary) + Text(". ") + Text(reason)
    }
}

extension SHAgentNotSignedInCard where Models == EmptyView {
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
