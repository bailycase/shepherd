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
    /// A Mac this app was a client of (`RemoteHostStore.notInFleet`), picked already with its saved address as its route.
    var candidate: FoundMac?
    /// The other ways in (a pairing link, SSH) show even while Macs are found nearby: the page's Add over SSH….
    var showsOtherWays = false
    /// Called once it is added, before the sheet closes.
    var onAdded: () -> Void = {}
    let dismiss: () -> Void

    @State private var picked: String?
    @State private var code: String

    init(model: FleetSettingsModel, candidate: FoundMac? = nil, code: String = "", picked: String? = nil, showsOtherWays: Bool = false,
         onAdded: @escaping () -> Void = {}, dismiss: @escaping () -> Void) {
        self.model = model
        self.candidate = candidate
        self.showsOtherWays = showsOtherWays
        self.onAdded = onAdded
        self.dismiss = dismiss
        _code = State(initialValue: code)
        _picked = State(initialValue: picked)
    }

    /// The Mac a link or an SSH find named, else the one picked from the Macs found.
    private var target: FleetSettingsModel.PairTarget? { model.target }
    private var mac: FoundMac? {
        target != nil ? nil : candidate ?? model.found.first { $0.id == picked } ?? (model.found.count == 1 ? model.found.first : nil)
    }
    /// No Mac is picked and the host can look the code up in iCloud, so the code alone is enough.
    private var findsByCode: Bool { mac == nil && target == nil && model.findsByCode }
    private var ready: Bool { (mac != nil || target != nil || findsByCode) && code.count == FleetProtocol.codeLength && model.pairing != .working }
    private var theirName: String { target?.name ?? mac?.name ?? "the other Mac" }
    /// Nothing is found nearby, or the person is using one of the other ways.
    private var offersOtherWays: Bool { showsOtherWays || (model.found.isEmpty && candidate == nil) || target != nil || !model.linkText.isEmpty || !model.sshTarget.isEmpty }

    var body: some View {
        SHSettingsSheet("Add a Mac to your fleet", subtitle: "Open Shepherd on the other Mac and choose Join a fleet.",
                        width: AppLayout.fleetPairWidth) {
            SHSheetHeading("Find the Mac")
            macs
            if offersOtherWays {
                linkWay
                sshWay
            }
            SHSheetRule()
            SHSheetHeading("Enter the code it shows")
            FleetCodeField(code: $code)
                .disabled(model.pairing == .working)
            SHSheetRule()
            SHSheetHeading("What \(target?.name ?? mac?.name ?? "it") gets")
            gets
        } status: {
            switch model.pairing {
            case .failed(let message): SHSheetStatus(message, tone: .failed)
            case .working: SHSheetStatus(mac == nil && target == nil ? "Looking for the Mac…" : "Adding \(theirName)…", tone: .now)
            case .idle: SHSheetStatus("The code proves it’s your Mac, whichever way you found it.")
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(.sh(.ghost)).keyboardShortcut(.cancelAction)
            Button((target?.name ?? mac?.name).map { "Add \($0)" } ?? "Add Mac") {
                Task {
                    let added: Bool
                    if let target {
                        added = await model.pair(at: target, code: code)
                    } else if let mac {
                        added = await model.pair(with: mac, code: code)
                    } else {
                        added = await model.pairByCode(code)
                    }
                    if added { onAdded(); dismiss() }
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
        model.readLink(text)
    }

    @ViewBuilder private var macs: some View {
        if let candidate {
            FleetFoundRow(mac: candidate, selected: mac?.id == candidate.id) {}
        } else if model.found.isEmpty {
            FleetNothingNearby(findsByCode: model.findsByCode)
        } else {
            VStack(spacing: SHSettingsSheetMetrics.pickRowGap) {
                ForEach(model.found) { found in
                    FleetFoundRow(mac: found, selected: mac?.id == found.id) { picked = found.id }
                }
            }
        }
    }

    /// Open a pairing link: the field and Paste. A link the other Mac shared fills in where it is and its code.
    private var linkWay: some View {
        let link = Binding(get: { model.linkText }, set: { model.readLink($0) })
        return FleetWayBox(title: "Open a pairing link",
                           detail: "The other Mac’s Join screen can send one by AirDrop or Messages. Opening it fills in where to find it and its code.",
                           on: model.link != nil) {
            HStack(spacing: SHSettingsSheetMetrics.rowGap) {
                SHSheetField(failed: model.linkProblem != nil) {
                    TextField("", text: link, prompt: Text("shepherd://fleet/join?…").foregroundStyle(Color.sh.textTertiary))
                        .textFieldStyle(.plain)
                        .font(.shMono(SHSettingsSheetMetrics.monoSize))
                        .foregroundStyle(Color.sh.textPrimary)
                        .disabled(model.pairing == .working)
                        .accessibilityLabel("Pairing link")
                }
                Button("Paste") { if let text = NSPasteboard.general.string(forType: .string) { model.readLink(text) } }
                    .buttonStyle(.sh(.secondary))
            }
            if let problem = model.linkProblem { SHSheetFieldNote(problem, tone: .failed) }
        }
    }

    private var sshFound: Bool {
        if case .found = model.ssh { return true }
        return false
    }

    /// Connect over SSH: `user@host`, and Find. Finds only; the code still pairs.
    private var sshWay: some View {
        FleetWayBox(title: "Connect over SSH",
                    detail: "For a Mac you already reach with ssh. Shepherd asks it where it listens, then you enter its code.",
                    on: sshFound) {
            HStack(spacing: SHSettingsSheetMetrics.rowGap) {
                SHSheetField {
                    TextField("", text: Binding(get: { model.sshTarget }, set: { model.sshTarget = $0 }),
                              prompt: Text("user@host").foregroundStyle(Color.sh.textTertiary))
                        .textFieldStyle(.plain)
                        .font(.shMono(SHSettingsSheetMetrics.monoSize))
                        .foregroundStyle(Color.sh.textPrimary)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await model.findOverSSH() } }
                        .accessibilityLabel("ssh address")
                }
                Button("Find") { Task { await model.findOverSSH() } }
                    .buttonStyle(.sh(.secondary))
                    .disabled(!model.canFindOverSSH)
            }
            switch model.ssh {
            case .idle: EmptyView()
            case .finding:
                SHSheetFieldNote("Asking over ssh…", tone: .now)
            case .found(let found):
                Text("Found " + ([found.name, found.address] + [found.version].compactMap { $0 }).joined(separator: " · "))
                    .font(.shSans(SHSettingsSheetMetrics.smallSize, .medium))
                    .foregroundStyle(Color.sh.textPrimary)
                    .padding(.top, SH.Space.s)
            case .failed(let message):
                SHSheetFieldNote(message, tone: .failed)
            }
        }
    }

    /// What the new Mac gets, and what it doesn't: three plain lines.
    private var gets: some View {
        SHSheetLines(["The fleet’s settings, instructions, skills, extensions, MCP servers and model sign-ins",
                      "Threads from any Mac, and work the fleet sends it",
                      "Not your checkouts. Each Mac keeps its own repos, and work runs in a new worktree there."])
    }
}

/// No Mac found on this network: said once, with what to do when the other Mac is on another network, VPN or VLAN.
struct FleetNothingNearby: View {
    var findsByCode = false

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.xxs) {
            Text("No Macs found nearby").font(.shSans(SHSettingsSheetMetrics.textSize, .medium)).foregroundStyle(Color.sh.textPrimary)
            SHSheetParagraph(Text("Still looking on this network. If the other Mac is on another network, VPN or VLAN, use one of these."
                                  + (findsByCode ? " Or enter its code and Shepherd looks through your iCloud." : "")), style: .small)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One way to find a Mac that Bonjour can't (a pairing link, SSH): its name over what it does, and its controls, on a quiet tile
/// while it is the one in use.
struct FleetWayBox<Content: View>: View {
    let title: String
    let detail: String
    let on: Bool
    @ViewBuilder var content: Content

    var body: some View {
        SHSheetGroup(on: on) {
            Text(title).font(.shSans(SHSettingsSheetMetrics.textSize, .medium)).foregroundStyle(Color.sh.textPrimary)
            SHSheetParagraph(detail, style: .small)
                .padding(.top, SH.Space.xxs).padding(.bottom, AppLayout.fleetWayGap)
            content
        }
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
        let M = SHSettingsSheetMetrics.self
        Button(action: pick) {
            HStack(spacing: M.pickGap) {
                SHGlyph.Settings.computer.image
                    .foregroundStyle(sh.textPrimary)
                    .frame(width: M.pickGlyph)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(mac.name).font(.shSans(M.textSize, selected ? .medium : .regular)).foregroundStyle(sh.textPrimary)
                        .frame(minHeight: M.baseLine)
                    Text(mac.address ?? "").font(.shSans(M.smallSize)).foregroundStyle(sh.textTertiary)
                        .frame(minHeight: M.baseLine)
                }
                Spacer(minLength: SH.Space.l)
                if let version = mac.version {
                    Text("Shepherd \(version)").font(.shSans(M.smallSize)).foregroundStyle(sh.textTertiary)
                }
            }
            .padding(.horizontal, M.pickSides)
            .padding(.vertical, SH.Space.s)
            .frame(maxWidth: .infinity, minHeight: M.pickHeight, alignment: .leading)
            .background(selected ? sh.bgSelected : Color.clear, in: RoundedRectangle(cornerRadius: M.pickRadius))
            .padding(.horizontal, -M.pickSides)
            .contentShape(RoundedRectangle(cornerRadius: M.pickRadius))
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
        ZStack(alignment: .leading) {
            HStack(spacing: SH.Space.m) {
                ForEach(0..<FleetProtocol.codeLength, id: \.self) { index in
                    let digit = Array(code).indices.contains(index) ? String(Array(code)[index]) : ""
                    let current = focused && index == min(code.count, FleetProtocol.codeLength - 1)
                    Text(digit)
                        .font(.shMono(AppLayout.fleetDigitSize, .medium))
                        .foregroundStyle(sh.textPrimary)
                        .frame(width: AppLayout.fleetDigitWidth, height: AppLayout.fleetDigitHeight)
                        .background(sh.bgHover, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                        .overlay {
                            RoundedRectangle(cornerRadius: SH.Radius.m)
                                .strokeBorder(current ? sh.textTertiary : sh.lineStrong, lineWidth: SHSettingsNavMetrics.borderWidth)
                        }
                        .background {
                            if current {
                                RoundedRectangle(cornerRadius: SH.Radius.m + SHSettingsSheetMetrics.focusRing).fill(sh.bgSelected)
                                    .padding(-SHSettingsSheetMetrics.focusRing)
                            }
                        }
                        .padding(.leading, index == FleetProtocol.codeLength / 2 ? AppLayout.fleetDigitGroupGap : 0)
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
