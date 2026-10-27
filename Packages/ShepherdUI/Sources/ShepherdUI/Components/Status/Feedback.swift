import SwiftUI

/// An inline banner inside the pane it concerns (Status board): a question, a failure, a
/// reconnecting host, a finished mission. Never a modal alert for an agent event.
public struct SHBanner<Actions: View>: View {
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
        let sh = Color.sh
        HStack(alignment: .top, spacing: SH.Space.l) {
            Image(systemName: systemImage ?? Self.defaultSymbol(state))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(state.color)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xs) {
                Text(title)
                    .font(.shSans(13, .semibold))
                    .foregroundStyle(state == .attention ? sh.lanternText : sh.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let message {
                    Text(message)
                        .font(.shSans(12.5))
                        .lineSpacing(3)
                        .foregroundStyle(sh.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            HStack(spacing: SH.Space.s) { actions() }
        }
        .padding(.vertical, SH.Space.l)
        .padding(.horizontal, 14)
        .background(state.tint ?? sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .shBorder(sh.lineSubtle, radius: SH.Radius.m)
        .accessibilityElement(children: .contain)
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

extension SHBanner where Actions == EmptyView {
    public init(_ state: AgentState, title: String, message: String? = nil, systemImage: String? = nil) {
        self.init(state, title: title, message: message, systemImage: systemImage) { EmptyView() }
    }
}

/// A transient note about a background agent event ("worker finished · 5 files").
/// Shown bottom-trailing by `.shToast(item:)`, one at a time, for 4 seconds.
public struct SHToast: Identifiable, Equatable {
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

    public static func == (a: SHToast, b: SHToast) -> Bool { a.id == b.id }
}

extension View {
    /// Shows `item` bottom-trailing for 4 seconds, then clears it. A new item replaces the
    /// current one.
    public func shToast(item: Binding<SHToast?>) -> some View {
        modifier(SHToastModifier(item: item))
    }
}

private struct SHToastModifier: ViewModifier {
    @Binding var item: SHToast?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            ZStack {
                if let toast = item {
                    SHToastView(toast: toast) { item = nil }
                        .padding(SH.Space.xl)
                        // Keyed by id: a toast that replaces another rises in as the old one leaves.
                        .id(toast.id)
                        .shTransition(.sheet, edge: .bottom)
                        .task(id: toast.id) {
                            try? await Task.sleep(for: .seconds(4))
                            if item?.id == toast.id { item = nil }
                        }
                }
            }
            .shAnimation(.sheet, value: item?.id)
        }
    }
}

struct SHToastView: View {
    let toast: SHToast
    let dismiss: () -> Void

    var body: some View {
        let sh = Color.sh
        HStack(spacing: 10) {
            SHStatusDot(toast.state, size: 7)
            Group {
                if let subject = toast.subject {
                    Text("\(Text(subject).fontWeight(.semibold)) \(toast.message)")
                } else {
                    Text(toast.message)
                }
            }
            .font(.shSans(12.5))
            .foregroundStyle(sh.textPrimary)
            .lineLimit(2)
            if let action = toast.action {
                Button(action.title) {
                    action.perform()
                    dismiss()
                }
                .buttonStyle(.sh(.ghost, size: .s))
            }
        }
        .padding(.leading, SH.Space.l)
        .padding(.trailing, SH.Space.m)
        .frame(minHeight: 36)
        .shPopover(radius: SH.Radius.m)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// An empty state (Status board): the crook, one title, one sentence, one or two actions.
public struct SHEmptyState<Actions: View>: View {
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
        let sh = Color.sh
        VStack(spacing: 10) {
            if showsMark { SHCrook().frame(width: 28, height: 28) }
            title
                .font(.shSans(17, .semibold))
                .tracking(-0.34)
                .foregroundStyle(sh.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.shSans(12.5))
                .lineSpacing(3)
                .foregroundStyle(sh.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: SH.Space.s) { actions() }.padding(.top, SH.Space.xs)
        }
        .padding(.vertical, 28)
        .padding(.horizontal, SH.Space.xl)
        .frame(maxWidth: .infinity)
        .shBorder(framed ? sh.lineStrong : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.m), dash: [4, 3])
    }
}

extension SHEmptyState where Actions == EmptyView {
    public init(_ title: Text, message: String, showsMark: Bool = true, framed: Bool = false) {
        self.init(title, message: message, showsMark: showsMark, framed: framed) { EmptyView() }
    }
}

/// A list still loading (SHStatus: a remote host's list): four placeholder rows, each a 6pt dot
/// and an 8pt bar 10pt after it, the bars at 70%, 52%, 64% and 40% of the width, all in
/// `bgSelected`, pulsing (`shShimmer()`; static under Reduce Motion). VoiceOver hears "Loading".
public struct SHLoadingRows: View {
    static let widths: [CGFloat] = [0.70, 0.52, 0.64, 0.40]

    public init() {}

    public var body: some View {
        let fill = Color.sh.bgSelected
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Self.widths.indices, id: \.self) { index in
                    HStack(spacing: 10) {
                        Circle().fill(fill).frame(width: 6, height: 6)
                        RoundedRectangle(cornerRadius: SH.Radius.xs).fill(fill)
                            .frame(width: geo.size.width * Self.widths[index], height: 8)
                    }
                    .frame(height: SH.Height.row)
                }
            }
        }
        .frame(height: SH.Height.row * CGFloat(Self.widths.count))
        .shShimmer()
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}

extension View {
    /// Loading placeholders pulse (use with `.redacted(reason: .placeholder)`; SHStatus), the
    /// `pulse` motion; static under Reduce Motion. Live text shimmers with `shShimmer(active:)`.
    public func shShimmer() -> some View { modifier(SHPulse()) }
}

private struct SHPulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.shMotionPaused) private var motionPaused
    @State private var onScreen = false

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            TimelineView(.animation(minimumInterval: nil, paused: motionPaused || !onScreen)) { context in
                let _ = SHRenderProbe.tick("ui.pulseFrame")
                content.opacity(SHPhase.pulseOpacity(context.date))
            }
            .onAppear { onScreen = true }
            .onDisappear { onScreen = false }
        }
    }
}
