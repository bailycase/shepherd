import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Add a Mac (FleetPair): pick a Mac Bonjour found, enter the code its Join screen shows. This
/// Mac's host does the pairing, so the Mac it adds and every other member are introduced even
/// with this window the only thing open. There is no address field: a Mac that can't be found
/// shows its address on its own Join screen.
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

    private var mac: FoundMac? { model.found.first { $0.id == picked } ?? (model.found.count == 1 ? model.found.first : nil) }
    /// No Mac is picked and the host can look the code up in iCloud, so the code alone is enough.
    private var findsByCode: Bool { mac == nil && !asClient && model.findsByCode }
    private var ready: Bool { (mac != nil || findsByCode) && code.count == FleetProtocol.codeLength && model.pairing != .working }
    private var theirName: String { mac?.name ?? "the other Mac" }

    var body: some View {
        let sh = Color.sh
        SHDialog(asClient ? "Add a Mac" : "Add a Mac to your fleet", message: "Open Shepherd on the other Mac. It needs to be on the same local network.",
                 width: AppLayout.fleetPairWidth) {
            VStack(alignment: .leading, spacing: 0) {
                section("1 · Pick the Mac") { macs }
                SHHairline()
                section("2 · Enter the code it shows") {
                    Text("On \(theirName): Settings ▸ Fleet ▸ \(asClient ? "Add a device" : "Join a fleet"). The code lasts 5 minutes.")
                        .font(.sh(.ui))
                        .foregroundStyle(sh.textSecondary)
                    FleetCodeField(code: $code)
                        .disabled(model.pairing == .working)
                }
                SHHairline()
                section(asClient ? "What this Mac gets" : "What \(mac?.name ?? "it") gets") { asClient ? AnyView(clientGets) : AnyView(gets) }
                SHHairline()
            }
        } status: {
            switch model.pairing {
            case .failed(let message): SHDialogStatus(message, isError: true)
            case .working: SHDialogStatus(mac == nil ? "Looking for the Mac…" : "Adding \(theirName)…")
            case .idle: SHDialogStatus(asClient ? "The Mac can revoke this one any time." : "You can remove a Mac from any Mac in the fleet.")
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(.sh(.ghost)).keyboardShortcut(.cancelAction)
            Button(mac.map { "Add \($0.name)" } ?? "Add Mac") {
                Task {
                    let added: Bool
                    if let mac {
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
        .task { model.startFinding() }
        .onDisappear { model.stopFinding() }
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

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            Text(title).shSectionLabel()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: SH.Space.l, leading: SHDialogMetrics.inset, bottom: SH.Space.l, trailing: SHDialogMetrics.inset))
    }

    @ViewBuilder private var macs: some View {
        if model.found.isEmpty {
            Text(findsByCode ? "Looking for Macs running Shepherd on this network… Not listed? Enter its code and Shepherd looks through your iCloud."
                             : "Looking for Macs running Shepherd on this network…")
                .font(.sh(.ui))
                .foregroundStyle(Color.sh.textTertiary)
        } else {
            ForEach(model.found) { found in
                FleetFoundRow(mac: found, selected: mac?.id == found.id) { picked = found.id }
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
