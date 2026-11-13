import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Add a Mac (FleetPair, FleetPairAnywhere): pick a Mac Bonjour found, or when none is found nearby open a pairing link the other
/// Mac shared, or find it over SSH; then enter the code its Join screen shows. This Mac's host does the pairing, so the Mac it adds
/// and every other member are introduced even with this window the only thing open. However the Mac was found, the code is the
/// only proof: it is checked by the same handshake, over a direct connection, after the answering Mac's id matches.
struct FleetPairSheet: View {
    var model: FleetSettingsModel
    /// Fleet is off: the Mac is added as one this app is a client of (what it shows is Add a device), not into a fleet.
    var asClient = false
    let dismiss: () -> Void

    @State private var picked: String?
    @State private var code: String

    init(model: FleetSettingsModel, asClient: Bool = false, code: String = "", dismiss: @escaping () -> Void) {
        self.model = model
        self.asClient = asClient
        self.dismiss = dismiss
        _code = State(initialValue: code)
    }

    /// The Mac a link or an SSH find named, else the one picked from the Macs found.
    private var target: FleetSettingsModel.PairTarget? { model.target }
    private var mac: FoundMac? {
        target != nil ? nil : model.found.first { $0.id == picked } ?? (model.found.count == 1 ? model.found.first : nil)
    }
    /// No Mac is picked and the host can look the code up in iCloud, so the code alone is enough.
    private var findsByCode: Bool { mac == nil && target == nil && !asClient && model.findsByCode }
    private var ready: Bool { (mac != nil || target != nil || findsByCode) && code.count == FleetProtocol.codeLength && model.pairing != .working }
    private var theirName: String { target?.name ?? mac?.name ?? "the other Mac" }
    /// Nothing is found nearby, or the person is using one of the other ways.
    private var offersOtherWays: Bool { model.found.isEmpty || target != nil || !model.linkText.isEmpty || !model.sshTarget.isEmpty }

    var body: some View {
        SHDialog(asClient ? "Add a Mac" : "Add a Mac to your fleet",
                 message: "Open Shepherd on the other Mac and choose \(asClient ? "Add a device" : "Join a fleet").",
                 width: AppLayout.fleetPairWidth) {
            VStack(alignment: .leading, spacing: 0) {
                section("1 · Find the Mac", first: true) {
                    macs
                    if offersOtherWays {
                        linkWay
                        sshWay
                    }
                }
                SHHairline()
                section("2 · Enter the code it shows") {
                    FleetCodeField(code: $code)
                        .disabled(model.pairing == .working)
                }
                SHHairline()
                section(asClient ? "What this Mac gets" : "What \(target?.name ?? mac?.name ?? "it") gets") { asClient ? AnyView(clientGets) : AnyView(gets) }
                SHHairline()
            }
        } status: {
            switch model.pairing {
            case .failed(let message): SHDialogStatus(message, isError: true)
            case .working: SHDialogStatus(mac == nil && target == nil ? "Looking for the Mac…" : "Adding \(theirName)…")
            case .idle: SHDialogStatus(asClient ? "The Mac can revoke this one any time." : "The code proves it's your Mac, whichever way you found it.")
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(.sh(.ghost)).keyboardShortcut(.cancelAction)
            Button((target?.name ?? mac?.name).map { "Add \($0)" } ?? "Add Mac") {
                Task {
                    let added: Bool
                    if let target {
                        added = await model.pair(at: target, code: code, asClient: asClient)
                    } else if let mac {
                        added = asClient ? await model.pairAsClient(with: mac, code: code) : await model.pair(with: mac, code: code)
                    } else {
                        added = await model.pairByCode(code)
                    }
                    if added { dismiss() }
                }
            }
            .buttonStyle(.sh(.primary)).keyboardShortcut(.defaultAction)
            .disabled(!ready)
        }
        .task {
            model.startFinding()
            takeIncomingLink()
        }
        .onChange(of: model.incomingLink) { takeIncomingLink() }
        // A link read fills in its code: the link is the other Mac's own way of saying it.
        .onChange(of: model.link) { if let link = model.link { code = link.code } }
        .onDisappear { model.stopFinding() }
    }

    /// A link opened from Finder, Messages or AirDrop fills in the link field.
    private func takeIncomingLink() {
        guard let text = model.incomingLink else { return }
        model.incomingLink = nil
        model.readLink(text, asClient: asClient)
    }

    /// A client of a Mac outside a fleet: its threads, and nothing of its settings.
    private var clientGets: some View {
        let sh = Color.sh
        return Grid(alignment: .topLeading, horizontalSpacing: SH.Space.m, verticalSpacing: SH.Space.s) {
            row(true, "Its threads in your sidebar: read them, send, start new ones and answer questions")
            row(false, "Not a fleet. Its settings, sign-ins and checkouts stay on it, and this Mac keeps its own.")
        }
        .font(.sh(.ui))
        .foregroundStyle(sh.textSecondary)
    }

    private func section<Content: View>(_ title: String, first: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            Text(title).shSectionLabel()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: first ? 0 : SH.Space.l, leading: SHDialogMetrics.inset, bottom: SH.Space.l, trailing: SHDialogMetrics.inset))
    }

    @ViewBuilder private var macs: some View {
        if model.found.isEmpty {
            FleetNothingNearby(findsByCode: !asClient && model.findsByCode)
        } else {
            ForEach(model.found) { found in
                FleetFoundRow(mac: found, selected: mac?.id == found.id) { picked = found.id }
            }
        }
    }

    /// Open a pairing link: the field and Paste. A link the other Mac shared fills in where it is and its code.
    private var linkWay: some View {
        let link = Binding(get: { model.linkText }, set: { model.readLink($0, asClient: asClient) })
        return FleetWayBox(glyph: Image(systemName: "link"), title: "Open a pairing link",
                           detail: "The other Mac's Join screen can send one by AirDrop or Messages. Opening it fills in where to find it and its code.",
                           on: model.link != nil) {
            HStack(spacing: SH.Space.s) {
                TextField("shepherd://fleet/join?…", text: link)
                    .textFieldStyle(.sh(mono: true, error: model.linkProblem != nil))
                    .disabled(model.pairing == .working)
                    .accessibilityLabel("Pairing link")
                Button("Paste") { if let text = NSPasteboard.general.string(forType: .string) { model.readLink(text, asClient: asClient) } }
                    .buttonStyle(.sh(.secondary))
            }
            if let problem = model.linkProblem {
                Text(problem).font(.sh(.caption)).foregroundStyle(Color.sh.failed).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sshFound: Bool {
        if case .found = model.ssh { return true }
        return false
    }

    /// Connect over SSH: `user@host`, and Find. Finds only; the code still pairs.
    private var sshWay: some View {
        FleetWayBox(glyph: SHGlyph.Settings.terminal.image, title: "Connect over SSH",
                    detail: "For a Mac you already reach with ssh. Shepherd asks it where it listens, then you enter its code.",
                    on: sshFound) {
            HStack(spacing: SH.Space.s) {
                TextField("user@host", text: Binding(get: { model.sshTarget }, set: { model.sshTarget = $0 }))
                    .textFieldStyle(.sh(mono: true))
                    .autocorrectionDisabled()
                    .onSubmit { Task { await model.findOverSSH() } }
                    .accessibilityLabel("ssh address")
                Button("Find") { Task { await model.findOverSSH() } }
                    .buttonStyle(.sh(.secondary))
                    .disabled(!model.canFindOverSSH)
            }
            switch model.ssh {
            case .idle: EmptyView()
            case .finding:
                Text("Asking over ssh…").font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
            case .found(let found):
                HStack(spacing: SH.Space.s) {
                    Image(systemName: "checkmark").font(.shSans(AppLayout.fleetResultTick, .semibold)).accessibilityHidden(true)
                    Text("Found " + ([found.name, found.address] + [found.version].compactMap { $0 }).joined(separator: " · "))
                }
                .font(.sh(.caption))
                .foregroundStyle(Color.sh.done)
            case .failed(let message):
                Text(message).font(.sh(.caption)).foregroundStyle(Color.sh.failed).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var gets: some View {
        let sh = Color.sh
        return Grid(alignment: .topLeading, horizontalSpacing: SH.Space.m, verticalSpacing: SH.Space.s) {
            row(true, "The fleet's settings, instructions, skills, extensions, MCP servers and model sign-ins")
            row(true, "Threads from any Mac, and work the fleet sends it")
            row(false, "Not your checkouts. Each Mac keeps its own repos, and work runs in a new worktree there.")
        }
        .font(.sh(.ui))
        .foregroundStyle(sh.textSecondary)
    }

    private func row(_ yes: Bool, _ text: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Group {
                if yes { Image(systemName: "checkmark").foregroundStyle(Color.sh.done) }
                else { Image(systemName: "xmark").foregroundStyle(Color.sh.textTertiary) }
            }
                .font(.shSans(AppLayout.fleetGetsGlyphSize, .semibold))
                .frame(width: AppLayout.fleetGetsColumn)
                .accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// No Mac found on this network: said once, with what to do when the other Mac is on another network, VPN or VLAN.
struct FleetNothingNearby: View {
    var findsByCode = false

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.m) {
            SHGlyph.Settings.search.image
                .foregroundStyle(sh.textTertiary)
                .frame(width: AppLayout.fleetFoundGlyphSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text("No Macs found nearby").font(.sh(.ui, weight: .medium)).foregroundStyle(sh.textPrimary)
                Text("Still looking on this network. If the other Mac is on another network, VPN or VLAN, use one of these."
                     + (findsByCode ? " Or enter its code and Shepherd looks through your iCloud." : ""))
                    .font(.sh(.caption))
                    .foregroundStyle(sh.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SH.Space.l)
        .padding(.vertical, SH.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay { RoundedRectangle(cornerRadius: SH.Radius.m).strokeBorder(sh.lineStrong, style: StrokeStyle(lineWidth: 1, dash: AppLayout.fleetFromDash)) }
        .accessibilityElement(children: .combine)
    }
}

/// One way to find a Mac that Bonjour can't (a pairing link, SSH): a glyph, its name and what it does, and its controls. Outlined in
/// `running` while it is the one in use.
struct FleetWayBox<Content: View>: View {
    let glyph: Image
    let title: String
    let detail: String
    let on: Bool
    @ViewBuilder var content: Content

    var body: some View {
        let sh = Color.sh
        HStack(alignment: .top, spacing: SH.Space.l) {
            glyph
                .foregroundStyle(sh.textSecondary)
                .frame(width: AppLayout.fleetFoundGlyphSize)
                .padding(.top, SH.Space.xxs)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.s) {
                Text(title).font(.sh(.ui, weight: .medium)).foregroundStyle(sh.textPrimary)
                Text(detail).font(.sh(.caption)).foregroundStyle(sh.textTertiary).fixedSize(horizontal: false, vertical: true)
                content
            }
        }
        .padding(.horizontal, SH.Space.l)
        .padding(.vertical, SH.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(on ? sh.runningTint : Color.clear, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .overlay { RoundedRectangle(cornerRadius: SH.Radius.m).strokeBorder(on ? sh.running : sh.lineSubtle) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// A Mac Bonjour found: its monitor glyph, its name over its address, its Shepherd.
struct FleetFoundRow: View {
    let mac: FoundMac
    let selected: Bool
    let pick: () -> Void

    var body: some View {
        let sh = Color.sh
        Button(action: pick) {
            HStack(spacing: SH.Space.l) {
                SHGlyph.Settings.computer.image
                    .foregroundStyle(sh.textSecondary)
                    .frame(width: AppLayout.fleetFoundGlyphSize)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    Text(mac.name).font(.sh(.ui)).foregroundStyle(sh.textPrimary)
                    Text(mac.address ?? "").font(.sh(.micro)).foregroundStyle(sh.textTertiary)
                }
                Spacer(minLength: SH.Space.l)
                if let version = mac.version {
                    Text("Shepherd \(version)").font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                }
            }
            .padding(.horizontal, SH.Space.l)
            .padding(.vertical, SH.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? sh.runningTint : Color.clear, in: RoundedRectangle(cornerRadius: SH.Radius.m))
            .overlay { RoundedRectangle(cornerRadius: SH.Radius.m).strokeBorder(selected ? sh.running : sh.lineSubtle) }
            .contentShape(RoundedRectangle(cornerRadius: SH.Radius.m))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mac.name), \(mac.address ?? "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Six boxes for the code, two groups of three. One text field holds the digits (it takes a
/// pasted code too); the boxes only draw them.
struct FleetCodeField: View {
    @Binding var code: String
    @FocusState private var focused: Bool

    var body: some View {
        let sh = Color.sh
        ZStack {
            HStack(spacing: SH.Space.s) {
                ForEach(0..<FleetProtocol.codeLength, id: \.self) { index in
                    let digit = Array(code).indices.contains(index) ? String(Array(code)[index]) : ""
                    Text(digit)
                        .font(.shMono(SHTextStyle.display.size))
                        .foregroundStyle(sh.textPrimary)
                        .frame(width: AppLayout.fleetDigitWidth, height: AppLayout.fleetDigitHeight)
                        .background(sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                        .overlay {
                            RoundedRectangle(cornerRadius: SH.Radius.m)
                                .strokeBorder(focused && index == min(code.count, FleetProtocol.codeLength - 1) ? sh.running : sh.lineStrong)
                        }
                        .padding(.trailing, index == FleetProtocol.codeLength / 2 - 1 ? AppLayout.fleetDigitGroupGap - SH.Space.s : 0)
                }
            }
            .accessibilityHidden(true)
            TextField("Pairing code", text: $code)
                .textFieldStyle(.plain)
                .focused($focused)
                .foregroundStyle(Color.clear)
                .tint(Color.clear)
                .opacity(0.01)
                .onChange(of: code) {
                    let digits = String(code.filter(\.isNumber).prefix(FleetProtocol.codeLength))
                    if digits != code { code = digits }
                }
        }
        .fixedSize()
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onAppear { focused = true }
    }
}
