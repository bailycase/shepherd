import SwiftUI

/// What the OAuth sign-in sheet shows: its steps, and whether it's waiting, done, or failed.
public struct MCPSignInSheetModel: Equatable, Sendable {
    public enum Phase: Sendable { case waiting, done, failed }

    public struct Step: Equatable, Sendable, Identifiable {
        public enum State: Sendable { case pending, live, done, failed }
        public var id: String
        public var title: String
        public var note: String?
        public var state: State

        public init(id: String, title: String, note: String? = nil, state: State) {
            self.id = id
            self.title = title
            self.note = note
            self.state = state
        }
    }

    public var title: String
    public var subtitle: String
    public var steps: [Step]
    public var phase: Phase
    /// The technical reason behind a failure, shown by Details.
    public var details: String?

    public init(title: String, subtitle: String, steps: [Step], phase: Phase, details: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.steps = steps
        self.phase = phase
        self.details = details
    }
}

/// Sign in to a server with OAuth (MCPStates' MCPSignInSheet): found the sign-in server,
/// registered Shepherd, waiting in the browser; then done or failed.
public struct MCPSignInSheet: View {
    public struct Actions {
        public var copyLink: () -> Void
        public var openBrowser: () -> Void
        public var cancel: () -> Void
        public var done: () -> Void
        public var tryAgain: () -> Void

        public init(copyLink: @escaping () -> Void, openBrowser: @escaping () -> Void, cancel: @escaping () -> Void,
                    done: @escaping () -> Void, tryAgain: @escaping () -> Void) {
            self.copyLink = copyLink
            self.openBrowser = openBrowser
            self.cancel = cancel
            self.done = done
            self.tryAgain = tryAgain
        }

        public static let none = Actions(copyLink: {}, openBrowser: {}, cancel: {}, done: {}, tryAgain: {})
    }

    let model: MCPSignInSheetModel
    let actions: Actions
    @State private var showsDetails = false

    public init(_ model: MCPSignInSheetModel, actions: Actions) {
        self.model = model
        self.actions = actions
    }

    public var body: some View {
        let sh = Color.sh
        let M = SHMCPMetrics.self
        VStack(alignment: .leading, spacing: SH.Space.xl) {
            HStack(alignment: .center, spacing: SH.Space.l) {
                Image(systemName: "powerplug")
                    .font(.shSans(M.sheetTitleSize))
                    .foregroundStyle(sh.textPrimary)
                    .frame(width: M.sheetIconTile, height: M.sheetIconTile)
                    .background(sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    Text(model.title)
                        .font(.shSans(M.sheetTitleSize, .semibold))
                        .foregroundStyle(sh.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(model.subtitle)
                        .font(.shSans(M.sheetSubtitleSize))
                        .foregroundStyle(sh.textSecondary)
                }
            }
            VStack(alignment: .leading, spacing: SH.Space.l + SH.Space.xxs) {
                ForEach(model.steps) { step in
                    MCPSignInStepRow(step)
                }
            }
            .padding(SH.Space.l + SH.Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(sh.bgSunken, in: RoundedRectangle(cornerRadius: M.cardRadius))
            .shBorder(sh.lineSubtle, radius: M.cardRadius)
            if showsDetails, let details = model.details {
                Text(details)
                    .font(.shMono(M.detailNoteSize))
                    .foregroundStyle(sh.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(SH.Space.xl + SH.Space.s)
        .frame(width: M.sheetWidth, alignment: .leading)
        .background(sh.bgWindow)
        .shAnimation(.disclosure, value: model)
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: SH.Space.m) {
            switch model.phase {
            case .waiting:
                Button(action: actions.copyLink) { Label("Copy link", systemImage: "doc.on.doc") }
                    .buttonStyle(.sh(.ghost))
                Spacer(minLength: SH.Space.m)
                Button("Cancel", action: actions.cancel).buttonStyle(.sh(.ghost)).keyboardShortcut(.cancelAction)
                Button(action: actions.openBrowser) { Label("Open browser again", systemImage: "arrow.up.forward.square") }
                    .buttonStyle(.sh(.secondary))
            case .done:
                Spacer(minLength: SH.Space.m)
                Button("Done", action: actions.done).buttonStyle(.sh(.primary)).keyboardShortcut(.defaultAction)
            case .failed:
                if model.details != nil {
                    Button(showsDetails ? "Hide details" : "Details") { showsDetails.toggle() }.buttonStyle(.sh(.ghost))
                }
                Spacer(minLength: SH.Space.m)
                Button("Close", action: actions.cancel).buttonStyle(.sh(.ghost)).keyboardShortcut(.cancelAction)
                Button(action: actions.tryAgain) { Label("Try again", systemImage: "arrow.clockwise") }
                    .buttonStyle(.sh(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// One step: a check when done, a live ring while it's happening, a cross when it failed, a
/// faint ring while it waits its turn.
public struct MCPSignInStepRow: View {
    let step: MCPSignInSheetModel.Step

    public init(_ step: MCPSignInSheetModel.Step) {
        self.step = step
    }

    public var body: some View {
        let sh = Color.sh
        let M = SHMCPMetrics.self
        HStack(alignment: .top, spacing: M.sheetStepGap) {
            mark.frame(width: M.sheetStepIcon, height: M.sheetStepIcon).padding(.top, 1)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(step.title)
                    .font(.shSans(M.sheetStepTitleSize))
                    .foregroundStyle(step.state == .pending ? sh.textTertiary : sh.textPrimary)
                    .shShimmer(active: step.state == .live)
                if let note = step.note {
                    Text(note)
                        .shText(size: M.sheetStepNoteSize, lineHeight: 1.4)
                        .foregroundStyle(sh.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var mark: some View {
        let sh = Color.sh
        switch step.state {
        case .done:
            Image(systemName: "checkmark")
                .font(.shSans(9, .bold))
                .foregroundStyle(sh.done)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(sh.doneTint, in: Circle())
        case .failed:
            Image(systemName: "xmark")
                .font(.shSans(9, .bold))
                .foregroundStyle(sh.failed)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(sh.failedTint, in: Circle())
        case .live:
            ZStack {
                Circle().strokeBorder(sh.running, lineWidth: 1.5)
                Circle().fill(sh.running).padding(4)
            }
        case .pending:
            Circle().strokeBorder(sh.lineStrong, lineWidth: 1.5)
        }
    }
}
