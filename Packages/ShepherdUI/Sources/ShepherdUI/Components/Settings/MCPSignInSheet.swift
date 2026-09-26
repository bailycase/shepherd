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
        let nw = Color.nw
        let M = NWMCPMetrics.self
        VStack(alignment: .leading, spacing: NW.Space.xl) {
            HStack(alignment: .center, spacing: NW.Space.l) {
                Image(systemName: "powerplug")
                    .font(.nwSans(M.sheetTitleSize))
                    .foregroundStyle(nw.textPrimary)
                    .frame(width: M.sheetIconTile, height: M.sheetIconTile)
                    .background(nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.m))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: NW.Space.xxs) {
                    Text(model.title)
                        .font(.nwSans(M.sheetTitleSize, .semibold))
                        .foregroundStyle(nw.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(model.subtitle)
                        .font(.nwSans(M.sheetSubtitleSize))
                        .foregroundStyle(nw.textSecondary)
                }
            }
            VStack(alignment: .leading, spacing: NW.Space.l + NW.Space.xxs) {
                ForEach(model.steps) { step in
                    MCPSignInStepRow(step)
                }
            }
            .padding(NW.Space.l + NW.Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(nw.bgSunken, in: RoundedRectangle(cornerRadius: M.cardRadius))
            .nwBorder(nw.lineSubtle, radius: M.cardRadius)
            if showsDetails, let details = model.details {
                Text(details)
                    .font(.nwMono(M.detailNoteSize))
                    .foregroundStyle(nw.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(NW.Space.xl + NW.Space.s)
        .frame(width: M.sheetWidth, alignment: .leading)
        .background(nw.bgWindow)
        .nwAnimation(.disclosure, value: model)
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: NW.Space.m) {
            switch model.phase {
            case .waiting:
                Button(action: actions.copyLink) { Label("Copy link", systemImage: "doc.on.doc") }
                    .buttonStyle(.nw(.ghost))
                Spacer(minLength: NW.Space.m)
                Button("Cancel", action: actions.cancel).buttonStyle(.nw(.ghost)).keyboardShortcut(.cancelAction)
                Button(action: actions.openBrowser) { Label("Open browser again", systemImage: "arrow.up.forward.square") }
                    .buttonStyle(.nw(.secondary))
            case .done:
                Spacer(minLength: NW.Space.m)
                Button("Done", action: actions.done).buttonStyle(.nw(.primary)).keyboardShortcut(.defaultAction)
            case .failed:
                if model.details != nil {
                    Button(showsDetails ? "Hide details" : "Details") { showsDetails.toggle() }.buttonStyle(.nw(.ghost))
                }
                Spacer(minLength: NW.Space.m)
                Button("Close", action: actions.cancel).buttonStyle(.nw(.ghost)).keyboardShortcut(.cancelAction)
                Button(action: actions.tryAgain) { Label("Try again", systemImage: "arrow.clockwise") }
                    .buttonStyle(.nw(.primary))
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
        let nw = Color.nw
        let M = NWMCPMetrics.self
        HStack(alignment: .top, spacing: M.sheetStepGap) {
            mark.frame(width: M.sheetStepIcon, height: M.sheetStepIcon).padding(.top, 1)
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text(step.title)
                    .font(.nwSans(M.sheetStepTitleSize))
                    .foregroundStyle(step.state == .pending ? nw.textTertiary : nw.textPrimary)
                    .nwShimmer(active: step.state == .live)
                if let note = step.note {
                    Text(note)
                        .nwText(size: M.sheetStepNoteSize, lineHeight: 1.4)
                        .foregroundStyle(nw.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var mark: some View {
        let nw = Color.nw
        switch step.state {
        case .done:
            Image(systemName: "checkmark")
                .font(.nwSans(9, .bold))
                .foregroundStyle(nw.done)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(nw.doneTint, in: Circle())
        case .failed:
            Image(systemName: "xmark")
                .font(.nwSans(9, .bold))
                .foregroundStyle(nw.failed)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(nw.failedTint, in: Circle())
        case .live:
            ZStack {
                Circle().strokeBorder(nw.running, lineWidth: 1.5)
                Circle().fill(nw.running).padding(4)
            }
        case .pending:
            Circle().strokeBorder(nw.lineStrong, lineWidth: 1.5)
        }
    }
}
