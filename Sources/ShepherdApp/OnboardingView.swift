import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// The measures of the Onboarding boards' `gob` markup: a 760 × 520 card, a 52pt strip of step dots, a body 72pt in from its sides and a 72pt foot.
extension AppLayout {
    static let onboardingWidth: CGFloat = 760
    static let onboardingHeight: CGFloat = 520
    static let onboardingRadius: CGFloat = SH.Radius.xxl + SH.Space.xs
    static let onboardingTop: CGFloat = 52
    static let onboardingFoot: CGFloat = 72
    static let onboardingSides: CGFloat = 72
    static let onboardingDot: CGFloat = 6
    static let onboardingDotOn: CGFloat = 22
    static let onboardingTitleSize: CGFloat = 28
    static let onboardingTitleLine: CGFloat = 34
    static let onboardingLeadSize: CGFloat = 15
    static let onboardingLeadWidth: CGFloat = 470
    static let onboardingListWidth: CGFloat = 520
    static let onboardingRowHeight: CGFloat = 44
    static let onboardingRowRadius: CGFloat = 10
    static let onboardingIcon: CGFloat = 28
    static let onboardingMark: CGFloat = 112
    static let onboardingMarkRadius: CGFloat = 26
    static let onboardingMarkGlyph: CGFloat = 68
    static let onboardingMarkTop: CGFloat = 56
    static let onboardingStepTop: CGFloat = 40
    static let onboardingScan: CGFloat = 64
    static let onboardingRadio: CGFloat = 16
    static let onboardingTick: CGFloat = 18
    static let onboardingButtonHeight: CGFloat = 32
    static let onboardingComposeWidth: CGFloat = 560
    static let onboardingSend: CGFloat = 28
    static let onboardingBalanceSlack: CGFloat = 12
    static let onboardingBalanceShare: CGFloat = 1.1
    static let onboardingScanGlyph: CGFloat = 22
    static let onboardingIconGlyph: CGFloat = 14
    /// Four rows of the picker before it scrolls.
    static let onboardingPickHeight: CGFloat = 4 * (onboardingRowHeight + SH.Space.xs)
}

/// The brand mark (the crook the Welcome board draws): `M9 22V9.5a5 5 0 0 1 10 0v.5a2.5 2.5 0 0 1-5 0` in a 14 × 21 box.
struct OnboardingCrook: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + (x - 7) / 14 * rect.width, y: rect.minY + (y - 3) / 21 * rect.height) }
        var path = Path()
        path.move(to: point(9, 22))
        path.addLine(to: point(9, 9.5))
        path.addArc(center: point(14, 9.5), radius: 5 / 14 * rect.width, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: point(19, 10))
        path.addArc(center: point(16.5, 10), radius: 2.5 / 14 * rect.width, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        return path
    }
}

/// Over the window until setup ends; Settings, sheets and pairing open over it.
struct OnboardingOverlay: View {
    var vm: ShepherdViewModel

    var body: some View {
        if vm.onboarding.isActive {
            ZStack {
                OnboardingWall()
                OnboardingView(vm: vm)
            }
            .ignoresSafeArea()
            .transition(.opacity)
            .accessibilityElement(children: .contain).accessibilityAddTraits(.isModal)
        }
    }
}

/// The desktop behind the card (`gthr-wall`): the window color with a warm light at the top right and a shade at the bottom left.
private struct OnboardingWall: View {
    var body: some View {
        let sh = Color.sh
        ZStack {
            sh.bgBase
            RadialGradient(colors: [sh.lanternTint, .clear], center: .init(x: 0.78, y: 0.08), startRadius: 0, endRadius: 700)
            RadialGradient(colors: [sh.textTertiary.opacity(0.26), .clear], center: .init(x: 0.08, y: 1), startRadius: 0, endRadius: 600)
        }
    }
}

struct OnboardingView: View {
    var vm: ShepherdViewModel
    private var model: OnboardingModel { vm.onboarding }
    @State private var pairing: FoundMac?
    @State private var browsing = false

    var body: some View {
        VStack(spacing: 0) {
            dots
            ZStack {
                switch model.step {
                case .welcome: welcome
                case .pi: pi
                case .signIn: signIn
                case .space: space
                case .fleet: fleet
                case .ready: ready
                }
            }
            .id(model.step)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, AppLayout.onboardingSides)
            foot
        }
        .frame(width: AppLayout.onboardingWidth, height: AppLayout.onboardingHeight)
        .background(Color.sh.bgWindow.opacity(0.82), in: RoundedRectangle(cornerRadius: AppLayout.onboardingRadius))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppLayout.onboardingRadius))
        .clipShape(RoundedRectangle(cornerRadius: AppLayout.onboardingRadius))
        .shBorder(Color.sh.lineSubtle, radius: AppLayout.onboardingRadius)
        .shPopover()
        .shAnimation(.content, value: model.step)
        .accessibilityElement(children: .contain).accessibilityLabel("Welcome to Shepherd")
        .sheet(item: $pairing) { mac in
            FleetPairSheet(model: vm.fleet, candidate: mac) { pairing = nil }.dialogSheetFrame()
        }
        .sheet(isPresented: $browsing) {
            RemoteDirectoryPicker(title: "Choose directory", actionTitle: "Choose", hostName: "This Mac", startPath: "",
                                  list: { try await LocalDirectoryLister.load(path: $0) },
                                  choose: { model.choose(folder: $0); browsing = false }, cancel: { browsing = false })
        }
    }

    // MARK: Chrome

    /// The step dots (`gob-dots`): a 6pt dot per step, the one shown a 22pt bar, the ones passed a darker dot you can go back to.
    private var dots: some View {
        HStack(spacing: SH.Space.s) {
            ForEach(model.steps, id: \.self) { step in
                let on = step == model.step, done = step < model.step
                Button { model.go(to: step) } label: {
                    Capsule().fill(on ? Color.sh.textPrimary : done ? Color.sh.textTertiary : Color.sh.lineSubtle)
                        .frame(width: on ? AppLayout.onboardingDotOn : AppLayout.onboardingDot, height: AppLayout.onboardingDot)
                        .frame(height: AppLayout.onboardingTop).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!done).accessibilityLabel(step.title)
                    .accessibilityAddTraits(on ? .isSelected : [])
            }
        }.frame(maxWidth: .infinity).frame(height: AppLayout.onboardingTop).shAnimation(.content, value: model.step)
    }

    /// Back at the left; at the right a quiet way past the step and the one action.
    private var foot: some View {
        HStack(spacing: SH.Space.l) {
            if !model.isFirst {
                Button("Back") { model.back() }.buttonStyle(OnboardingBackStyle())
            }
            Spacer(minLength: 0)
            if let skip = skipTitle {
                Button(skip) { advance() }.buttonStyle(OnboardingButtonStyle(ghost: true))
            }
            Button(primaryTitle) { primary() }.buttonStyle(OnboardingButtonStyle()).disabled(!primaryEnabled)
                .keyboardShortcut(.defaultAction)
        }.padding(.horizontal, SH.Space.xxl).frame(height: AppLayout.onboardingFoot)
    }

    private var skipTitle: String? {
        switch model.step {
        case .signIn, .space: "Skip"
        case .fleet: "Not now"
        default: nil
        }
    }

    private var primaryTitle: String {
        switch model.step {
        case .welcome: "Get started"
        case .space: "Add space"
        case .ready: "Start thread"
        default: "Continue"
        }
    }

    private var primaryEnabled: Bool {
        switch model.step {
        case .pi: vm.yourPi.importSheet?.stage != .progress
        case .space: model.selection != nil && !model.adding
        case .ready: !model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.addedSpace != nil
        default: true
        }
    }

    private func advance() {
        if model.step == .ready { finish() } else { model.next() }
    }

    private func primary() {
        switch model.step {
        case .space:
            guard let path = model.selection else { return }
            model.setAdding(true)
            Task {
                let id = await vm.addSpace(at: URL(fileURLWithPath: path), select: false)
                model.added(id)
                model.setAdding(false, problem: id == nil ? "Couldn’t add that folder. Choose another." : nil)
                if id != nil { model.next() }
            }
        case .ready:
            startThread()
        default:
            model.next()
        }
    }

    private func startThread() {
        guard let id = model.addedSpace else { return }
        vm.newThread.choose(host: nil, space: id, vm: vm)
        vm.newThread.prompt = model.prompt
        finish()
        vm.newThread.send(vm)
    }

    /// Ends setup: the window shows what is there, and the copy's hold on restored agents is over.
    private func finish() {
        model.finish()
        vm.finishImport()
        vm.fleet.stopFinding()
    }

    // MARK: Steps

    /// The widest a line of `text` may be so that its lines come out about as long as each other (the boards' `text-wrap: balance`).
    private func balanced(_ text: String) -> CGFloat {
        let size = AppLayout.onboardingLeadSize * ThemeStore.shared.textScale
        let width = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width
        let lines = (width / (AppLayout.onboardingLeadWidth * ThemeStore.shared.textScale)).rounded(.up)
        return lines <= 1 ? AppLayout.onboardingLeadWidth : min(AppLayout.onboardingLeadWidth, width / lines / ThemeStore.shared.textScale * AppLayout.onboardingBalanceShare + AppLayout.onboardingBalanceSlack)
    }

    private func heading(_ title: String, _ lead: Text?, balance: String? = nil, top: CGFloat = AppLayout.onboardingStepTop) -> some View {
        VStack(spacing: SH.Space.m) {
            Text(title).font(.shSans(AppLayout.onboardingTitleSize, .semibold)).tracking(-0.02 * AppLayout.onboardingTitleSize)
                .foregroundStyle(Color.sh.textPrimary).multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
            if let lead {
                lead.shText(size: AppLayout.onboardingLeadSize, lineHeight: 22 / AppLayout.onboardingLeadSize).foregroundStyle(Color.sh.textSecondary)
                    .multilineTextAlignment(.center).frame(maxWidth: balance.map(balanced) ?? AppLayout.onboardingLeadWidth).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.top, top)
    }

    private static let welcomeLead = "Run coding agents across your Macs, and keep every thread, question and change in one place."
    private static let signInLead = "Use a subscription you already pay for, or an API key. You can add more later."
    private static let spaceLead = "A space is a folder with a repo. Every thread in it gets its own worktree."
    private static let fleetLead = "Threads run on whichever Mac has room. Each Mac needs Shepherd open."

    private var welcome: some View {
        VStack(spacing: 0) {
            OnboardingCrook().stroke(Color.sh.textPrimary, style: StrokeStyle(lineWidth: 2.2 / 14 * AppLayout.onboardingMarkGlyph * 0.5 + 1, lineCap: .round, lineJoin: .round))
                .frame(width: AppLayout.onboardingMarkGlyph * 14 / 21, height: AppLayout.onboardingMarkGlyph)
                .frame(width: AppLayout.onboardingMark, height: AppLayout.onboardingMark)
                .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: AppLayout.onboardingMarkRadius))
                .shLift(RoundedRectangle(cornerRadius: AppLayout.onboardingMarkRadius), fill: Color.sh.bgRaised)
                .overlay { RoundedRectangle(cornerRadius: AppLayout.onboardingMarkRadius).strokeBorder(Color.sh.lineSubtle) }
                .padding(.top, AppLayout.onboardingMarkTop).accessibilityHidden(true)
            heading("Welcome to Shepherd", Text(Self.welcomeLead), balance: Self.welcomeLead, top: SH.Space.xxxl)
            Text("Setup takes about a minute.").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).padding(.top, SH.Space.l)
        }
    }

    /// "Bringing over your pi": what the first launch's copy does, from `PiImportSheetState`.
    private var pi: some View {
        let state = vm.yourPi.importSheet
        let rows = state?.rows ?? []
        return VStack(spacing: 0) {
            heading("Bringing over your pi", Text("Once, from ") + Text((state?.from).map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "~/.pi/agent").font(.shMono(AppLayout.onboardingLeadSize - 3))
                .foregroundColor(Color.sh.textTertiary) + Text(". The pi in your terminal is untouched."))
            ProgressRule(done: state?.stage != .progress).padding(.top, SH.Space.xl)
            VStack(spacing: SH.Space.xs) {
                ForEach(rows) { row in
                    OnboardingRow(title: row.title, detail: row.detail) {
                        OnboardingTick(state: row.state)
                    } trailing: {
                        if let count = row.count { Text(count).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).lineLimit(1) }
                    }
                }
            }.padding(.top, SH.Space.l).frame(maxWidth: AppLayout.onboardingListWidth)
            if let state, state.stage == .failed || state.report.signInsUnreadable != nil {
                HStack(spacing: SH.Space.l) {
                    Text(state.report.signInsUnreadable?.reason ?? "Your pi’s sign-ins couldn’t be copied.").font(.sh(.caption))
                        .foregroundStyle(Color.sh.failed).lineLimit(2)
                    Button(state.retrying ? "Trying…" : "Try again") { vm.retryImportSignIns() }.buttonStyle(SpaceLinkStyle(tone: .strong, caption: true))
                        .disabled(state.retrying)
                }.padding(.top, SH.Space.l)
            }
        }
    }

    private var providers: [(id: String, title: String, detail: String)] {
        [("anthropic", "Claude Pro or Max", "With your Claude Pro or Max subscription"),
         ("openai-codex", "ChatGPT Plus or Pro", "With your ChatGPT subscription"),
         ("github-copilot", "GitHub Copilot", "With your Copilot Pro or Business plan")]
    }

    private func signedIn(_ provider: String) -> Bool {
        guard let survey = vm.yourPi.survey else { return false }
        return !survey.missingSignIns(for: ["\(provider)/any"]).contains(provider)
    }

    private var signIn: some View {
        VStack(spacing: 0) {
            heading("Sign in to a model provider", Text(Self.signInLead), balance: Self.signInLead)
            VStack(spacing: SH.Space.xs) {
                ForEach(providers, id: \.id) { provider in
                    let ok = signedIn(provider.id)
                    OnboardingRow(title: provider.title, detail: provider.detail) {
                        OnboardingIcon(symbol: "person.badge.key", on: ok)
                    } trailing: {
                        if ok {
                            Text("Signed in").font(.sh(.ui)).foregroundStyle(Color.sh.textTertiary)
                        } else {
                            Button("Sign in") { vm.piAuth.signIn(provider.id, origin: .firstLaunch) }.buttonStyle(SpaceLinkStyle(tone: .strong))
                                .accessibilityLabel("Sign in to \(provider.title)")
                        }
                    }
                }
                OnboardingRow(title: "Use an API key", detail: "Anthropic, OpenAI, Google, OpenRouter and \(max(0, PiSignInCatalog.keyPages.count - 4)) more") {
                    OnboardingIcon(symbol: "person.badge.key", on: false)
                } trailing: {
                    Button("Add") { vm.settingsSection = .models; vm.showSettings = true }.buttonStyle(SpaceLinkStyle(tone: .strong))
                        .accessibilityLabel("Add an API key")
                }
            }.padding(.top, SH.Space.xxl).frame(maxWidth: AppLayout.onboardingListWidth)
        }
        .task(id: vm.piAuth.session == nil) { await vm.yourPi.refresh() }
        .task { if vm.piAuth.providers == nil { await vm.piAuth.refreshProviders() } }
    }

    private var space: some View {
        VStack(spacing: 0) {
            heading("Add your first space", Text(Self.spaceLead), balance: Self.spaceLead)
            ScrollView {
              VStack(spacing: SH.Space.xs) {
                ForEach(model.candidates) { candidate in
                    let on = model.selection == candidate.path
                    Button { model.selection = candidate.path } label: {
                        OnboardingRow(title: candidate.name, detail: candidate.display, on: on) {
                            OnboardingRadio(on: on)
                        } trailing: {
                            Text(candidate.branch).font(.shMono(SHTextStyle.caption.size)).foregroundStyle(Color.sh.textTertiary).lineLimit(1)
                        }
                    }.buttonStyle(.plain).accessibilityElement(children: .combine)
                        .accessibilityLabel("\(candidate.name), \(candidate.display)").accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                }
                if model.candidates.isEmpty {
                    Text(model.scanned ? "No repositories found in the usual folders." : "Looking for repositories…").font(.sh(.ui))
                        .foregroundStyle(Color.sh.textTertiary).padding(.vertical, SH.Space.xl)
                }
              }
            }.scrollIndicators(.never).frame(maxWidth: AppLayout.onboardingListWidth, maxHeight: AppLayout.onboardingPickHeight)
                .fixedSize(horizontal: false, vertical: true).padding(.top, SH.Space.xxl)
            HStack(spacing: SH.Space.xs) {
                Text(model.scanRoot.map { "Found in \($0)." } ?? "").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                Button("Choose another folder…") { browsing = true }.buttonStyle(SpaceLinkStyle(tone: .quiet, caption: true))
            }.padding(.top, SH.Space.l)
            if let problem = model.problem {
                Text(problem).font(.sh(.caption)).foregroundStyle(Color.sh.failed).padding(.top, SH.Space.m)
            }
        }
    }

    private var fleet: some View {
        VStack(spacing: 0) {
            heading("Add your other Macs", Text(Self.fleetLead), balance: Self.fleetLead)
            SHGlyph.Settings.computer.image.resizable().scaledToFit().frame(width: AppLayout.onboardingScanGlyph, height: AppLayout.onboardingScanGlyph)
                .foregroundStyle(Color.sh.textPrimary)
                .frame(width: AppLayout.onboardingScan, height: AppLayout.onboardingScan)
                .overlay { Circle().strokeBorder(Color.sh.textTertiary, lineWidth: SHProjectSettingsMetrics.line * 1.5) }
                .padding(.top, SH.Space.xxl).accessibilityHidden(true)
            VStack(spacing: SH.Space.xs) {
                ForEach(vm.fleet.found) { mac in
                    OnboardingRow(title: mac.name, detail: mac.version.map { "Nearby · Shepherd \($0)" } ?? "Nearby") {
                        OnboardingIcon(symbol: nil, on: false)
                    } trailing: {
                        Button("Add") { pairing = mac }.buttonStyle(SpaceLinkStyle(tone: .strong)).accessibilityLabel("Add \(mac.name)")
                    }
                }
                if vm.fleet.found.isEmpty {
                    Text("Looking for Macs nearby…").font(.sh(.ui)).foregroundStyle(Color.sh.textTertiary).padding(.top, SH.Space.m)
                }
            }.padding(.top, SH.Space.xl).frame(maxWidth: AppLayout.onboardingListWidth)
        }
        .onAppear { vm.fleet.startFinding() }
        .onDisappear { vm.fleet.stopFinding() }
    }

    private var ready: some View {
        let space = vm.state.spaces.first { $0.id == model.addedSpace }
        return VStack(spacing: 0) {
            heading("You’re ready", space.map { Text("Start your first thread in \($0.name). It runs on this Mac in its own worktree.") }
                    ?? Text("Start your first thread. It runs on this Mac."), top: AppLayout.onboardingMarkTop)
            VStack(alignment: .leading, spacing: SH.Space.l) {
                TextField("What should it work on?", text: Binding(get: { model.prompt }, set: { model.prompt = $0 }), axis: .vertical)
                    .textFieldStyle(.plain).font(.shSans(AppLayout.onboardingLeadSize)).foregroundStyle(Color.sh.textPrimary).lineLimit(1...4)
                    .accessibilityLabel("First thread")
                    .onSubmit { if primaryEnabled { primary() } }
                HStack(spacing: SH.Space.m) {
                    Image(systemName: "plus").accessibilityHidden(true)
                    Text("\(space?.name ?? "space") on This Mac")
                    Spacer(minLength: 0)
                    Text(vm.newThread.model.isEmpty ? "Default model" : NativeModelChoices.shortName(vm.newThread.model))
                    Text("\(vm.newThread.thinkingLevel(vm).title) effort")
                }.font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).lineLimit(1)
            }
            .padding(EdgeInsets(top: SH.Space.l, leading: SH.Space.xl, bottom: SH.Space.m, trailing: SH.Space.l))
            .frame(maxWidth: AppLayout.onboardingComposeWidth, alignment: .leading)
            .shCard(radius: SH.Radius.xxl, lift: true)
            .padding(.top, SH.Space.xxl)
            Text("⌘N starts a thread from anywhere.").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).padding(.top, SH.Space.l)
        }
    }
}

// MARK: Parts

/// A row (`gob-row`): a leading mark, a bold title over a caption, and what is at its end.
private struct OnboardingRow<Leading: View, Trailing: View>: View {
    let title: String
    var detail: String?
    var on = false
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: SH.Space.l) {
            leading
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
                if let detail { Text(detail).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).lineLimit(1).truncationMode(.middle) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, SH.Space.l).padding(.vertical, SH.Space.m).frame(minHeight: AppLayout.onboardingRowHeight)
        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: AppLayout.onboardingRowRadius))
        .overlay { RoundedRectangle(cornerRadius: AppLayout.onboardingRowRadius).strokeBorder(on ? Color.sh.textPrimary : Color.sh.lineSubtle, lineWidth: on ? 2 * SHProjectSettingsMetrics.line : SHProjectSettingsMetrics.line) }
        .contentShape(Rectangle())
    }
}

private struct OnboardingIcon: View {
    var symbol: String?
    let on: Bool

    var body: some View {
        Group {
            if let symbol { Image(systemName: symbol).font(.shSans(AppLayout.onboardingIconGlyph)) }
            else { SHGlyph.Settings.computer.image.resizable().scaledToFit().frame(width: AppLayout.onboardingIconGlyph, height: AppLayout.onboardingIconGlyph) }
        }.foregroundStyle(on ? Color.sh.textPrimary : Color.sh.textSecondary)
            .frame(width: AppLayout.onboardingIcon, height: AppLayout.onboardingIcon)
            .background(Color.sh.bgSelected, in: RoundedRectangle(cornerRadius: SH.Radius.m)).accessibilityHidden(true)
    }
}

private struct OnboardingRadio: View {
    let on: Bool

    var body: some View {
        ZStack {
            Circle().strokeBorder(on ? Color.sh.textPrimary : Color.sh.lineSubtle, lineWidth: on ? 5 : 1.5)
        }.frame(width: AppLayout.onboardingRadio, height: AppLayout.onboardingRadio).accessibilityHidden(true)
    }
}

/// A step's mark in the copy (`gob-tick`): a ring, filled with a check when it is done.
private struct OnboardingTick: View {
    let state: SHStepState

    var body: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(Color.sh.textPrimary)
                Image(systemName: "checkmark").font(.shSans(SHSettingsControlMetrics.popupChevronSize, .bold)).foregroundStyle(Color.sh.bgWindow)
            case .failed:
                Circle().fill(Color.sh.failed)
                Image(systemName: "xmark").font(.shSans(SHSettingsControlMetrics.popupChevronSize, .bold)).foregroundStyle(Color.sh.bgWindow)
            default:
                Circle().strokeBorder(Color.sh.lineSubtle, lineWidth: 1.5)
            }
        }.frame(width: AppLayout.onboardingTick, height: AppLayout.onboardingTick).shAnimation(.content, value: state).accessibilityHidden(true)
    }
}

/// The copy's progress rule (`gob-bar`): 3pt, full once it is done.
private struct ProgressRule: View {
    let done: Bool

    var body: some View {
        Capsule().fill(Color.sh.lineSubtle).frame(maxWidth: AppLayout.onboardingListWidth).frame(height: SH.Space.xs - SH.Space.xxs / 2)
            .overlay(alignment: .leading) {
                GeometryReader { geo in Capsule().fill(Color.sh.textPrimary).frame(width: geo.size.width * (done ? 1 : 0.35)) }
            }.shAnimation(.content, value: done).accessibilityHidden(true)
    }
}

private struct OnboardingBackStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary).padding(.horizontal, SH.Space.m).padding(.vertical, SH.Space.s)
            .background(hovering ? Color.sh.bgHover : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
            .contentShape(Rectangle()).onHover { hovering = $0 }.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// The foot's buttons (`gob-btn`): 32pt pills, the one action in ink, the way past in words.
private struct OnboardingButtonStyle: ButtonStyle {
    var ghost = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.sh(.ui, weight: ghost ? .regular : .semibold)).lineLimit(1)
            .foregroundStyle(ghost ? Color.sh.textSecondary : Color.sh.textOnPrimary)
            .padding(.horizontal, SH.Space.xl).frame(height: AppLayout.onboardingButtonHeight)
            .background {
                if ghost { Capsule().fill(hovering ? Color.sh.bgHover : .clear) }
                else { Capsule().fill(configuration.isPressed ? Color.sh.primaryPressed : hovering && enabled ? Color.sh.primaryHover : Color.sh.primary) }
            }
            .opacity(enabled ? 1 : AppLayout.spaceBarOffOpacity + 0.05).contentShape(Capsule()).onHover { hovering = $0 }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
