import SwiftUI

/// An inline banner inside the pane it concerns (Status board): a question, a failure, a
/// reconnecting host, a finished mission. Never a modal alert for an agent event.
public struct NWBanner<Actions: View>: View {
    let state: AgentState
    let title: String
    let message: String?
    let systemImage: String?
    @ViewBuilder let actions: () -> Actions

    public init(_ state: AgentState, title: String, message: String? = nil, systemImage: String? = nil,
                @ViewBuilder actions: @escaping () -> Actions) {
        self.state = state
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.actions = actions
    }

    public var body: some View {
        let nw = Color.nw
        HStack(alignment: .top, spacing: NW.Space.l) {
            Image(systemName: systemImage ?? Self.defaultSymbol(state))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(state.color)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NW.Space.xs) {
                Text(title)
                    .font(.nwSans(13, .semibold))
                    .foregroundStyle(state == .attention ? nw.lanternText : nw.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let message {
                    Text(message)
                        .font(.nwSans(12.5))
                        .lineSpacing(3)
                        .foregroundStyle(nw.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: NW.Space.s) { actions() }
        }
        .padding(.vertical, NW.Space.l)
        .padding(.horizontal, 14)
        .background(state.tint ?? nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.m))
        .nwBorder(nw.lineSubtle, radius: NW.Radius.m)
        .accessibilityElement(children: .combine)
    }

    static func defaultSymbol(_ state: AgentState) -> String {
        switch state {
        case .attention, .failed, .stuck: "exclamationmark.triangle"
        case .done: "checkmark"
        case .running: "arrow.clockwise"
        case .queued, .idle: "info.circle"
        }
    }
}

extension NWBanner where Actions == EmptyView {
    public init(_ state: AgentState, title: String, message: String? = nil, systemImage: String? = nil) {
        self.init(state, title: title, message: message, systemImage: systemImage) { EmptyView() }
    }
}

/// A transient note about a background agent event ("worker finished · 5 files").
/// Shown bottom-trailing by `.nwToast(item:)`, one at a time, for 4 seconds.
public struct NWToast: Identifiable, Equatable {
    public struct Action {
        public let title: String
        public let perform: @MainActor () -> Void

        public init(_ title: String, perform: @escaping @MainActor () -> Void) {
            self.title = title
            self.perform = perform
        }
    }

    public let id: UUID
    public let state: AgentState
    /// The bold lead ("worker").
    public let subject: String?
    public let message: String
    public let action: Action?

    public init(_ state: AgentState, subject: String? = nil, message: String, action: Action? = nil) {
        id = UUID()
        self.state = state
        self.subject = subject
        self.message = message
        self.action = action
    }

    public static func == (a: NWToast, b: NWToast) -> Bool { a.id == b.id }
}

extension View {
    /// Shows `item` bottom-trailing for 4 seconds, then clears it. A new item replaces the
    /// current one.
    public func nwToast(item: Binding<NWToast?>) -> some View {
        modifier(NWToastModifier(item: item))
    }
}

private struct NWToastModifier: ViewModifier {
    @Binding var item: NWToast?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            ZStack {
                if let toast = item {
                    NWToastView(toast: toast) { item = nil }
                        .padding(NW.Space.xl)
                        // Keyed by id: a toast that replaces another rises in as the old one leaves.
                        .id(toast.id)
                        .nwTransition(.sheet, edge: .bottom)
                        .task(id: toast.id) {
                            try? await Task.sleep(for: .seconds(4))
                            if item?.id == toast.id { item = nil }
                        }
                }
            }
            .nwAnimation(.sheet, value: item?.id)
        }
    }
}

struct NWToastView: View {
    let toast: NWToast
    let dismiss: () -> Void

    var body: some View {
        let nw = Color.nw
        HStack(spacing: 10) {
            NWStatusDot(toast.state, size: 7)
            Group {
                if let subject = toast.subject {
                    Text("\(Text(subject).fontWeight(.semibold)) \(toast.message)")
                } else {
                    Text(toast.message)
                }
            }
            .font(.nwSans(12.5))
            .foregroundStyle(nw.textPrimary)
            .lineLimit(2)
            if let action = toast.action {
                Button(action.title) {
                    action.perform()
                    dismiss()
                }
                .buttonStyle(.nw(.ghost, size: .s))
            }
        }
        .padding(.leading, NW.Space.l)
        .padding(.trailing, NW.Space.m)
        .frame(minHeight: 36)
        .nwPopover(radius: NW.Radius.m)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// An empty state (Status board): the crook, one title, one sentence, one or two actions.
public struct NWEmptyState<Actions: View>: View {
    let title: Text
    let message: String
    let showsMark: Bool
    let framed: Bool
    @ViewBuilder let actions: () -> Actions

    /// `title` is a `Text` so a part of it can be mono ("New agent in `~/dev`").
    public init(_ title: Text, message: String, showsMark: Bool = true, framed: Bool = false,
                @ViewBuilder actions: @escaping () -> Actions) {
        self.title = title
        self.message = message
        self.showsMark = showsMark
        self.framed = framed
        self.actions = actions
    }

    public var body: some View {
        let nw = Color.nw
        VStack(spacing: 10) {
            if showsMark { NWCrook().frame(width: 28, height: 28) }
            title
                .font(.nwSans(17, .semibold))
                .tracking(-0.34)
                .foregroundStyle(nw.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.nwSans(12.5))
                .lineSpacing(3)
                .foregroundStyle(nw.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: NW.Space.s) { actions() }.padding(.top, NW.Space.xs)
        }
        .padding(.vertical, 28)
        .padding(.horizontal, NW.Space.xl)
        .frame(maxWidth: .infinity)
        .nwBorder(framed ? nw.lineStrong : .clear, in: RoundedRectangle(cornerRadius: NW.Radius.m), dash: [4, 3])
    }
}

extension NWEmptyState where Actions == EmptyView {
    public init(_ title: Text, message: String, showsMark: Bool = true, framed: Bool = false) {
        self.init(title, message: message, showsMark: showsMark, framed: framed) { EmptyView() }
    }
}

extension View {
    /// Loading placeholders pulse (use with `.redacted(reason: .placeholder)`; NWStatus), the
    /// `pulse` motion; static under Reduce Motion. Live text shimmers with `nwShimmer(active:)`.
    public func nwShimmer() -> some View { modifier(NWPulse()) }
}

private struct NWPulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nwMotionPaused) private var motionPaused
    @State private var onScreen = false

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            TimelineView(.animation(minimumInterval: nil, paused: motionPaused || !onScreen)) { context in
                let _ = NWRenderProbe.tick("ui.pulseFrame")
                content.opacity(NWPhase.pulseOpacity(context.date))
            }
            .onAppear { onScreen = true }
            .onDisappear { onScreen = false }
        }
    }
}
