import SwiftUI
import ShepherdUI
import ShepherdProtocol

/// Add a Mac (FleetPair): pick a Mac Bonjour found, enter the code its Join screen shows. This
/// Mac's host does the pairing, so the Mac it adds and every other member are introduced even
/// with this window the only thing open. There is no address field: a Mac that can't be found
/// shows its address on its own Join screen.
struct FleetPairSheet: View {
    var model: FleetSettingsModel
    let dismiss: () -> Void

    @State private var picked: String?
    @State private var code: String

    init(model: FleetSettingsModel, code: String = "", dismiss: @escaping () -> Void) {
        self.model = model
        self.dismiss = dismiss
        _code = State(initialValue: code)
    }

    private var mac: FoundMac? { model.found.first { $0.id == picked } ?? (model.found.count == 1 ? model.found.first : nil) }
    private var ready: Bool { mac != nil && code.count == FleetProtocol.codeLength && model.pairing != .working }
    private var theirName: String { mac?.name ?? "the other Mac" }

    var body: some View {
        let sh = Color.sh
        SHDialog("Add a Mac to your fleet", message: "Open Shepherd on the other Mac. It needs to be on the same local network.",
                 width: AppLayout.fleetPairWidth) {
            VStack(alignment: .leading, spacing: 0) {
                section("1 · Pick the Mac") { macs }
                SHHairline()
                section("2 · Enter the code it shows") {
                    Text("On \(theirName): Settings ▸ Fleet ▸ Join a fleet. The code lasts 5 minutes.")
                        .font(.sh(.ui))
                        .foregroundStyle(sh.textSecondary)
                    FleetCodeField(code: $code)
                        .disabled(model.pairing == .working)
                }
                SHHairline()
                section("What \(mac?.name ?? "it") gets") { gets }
                SHHairline()
            }
        } status: {
            switch model.pairing {
            case .failed(let message): SHDialogStatus(message, isError: true)
            case .working: SHDialogStatus("Adding \(theirName)…")
            case .idle: SHDialogStatus("You can remove a Mac from any Mac in the fleet.")
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(.sh(.ghost)).keyboardShortcut(.cancelAction)
            Button(mac.map { "Add \($0.name)" } ?? "Add Mac") {
                guard let mac else { return }
                Task { if await model.pair(with: mac, code: code) { dismiss() } }
            }
            .buttonStyle(.sh(.primary)).keyboardShortcut(.defaultAction)
            .disabled(!ready)
        }
        .task { model.startFinding() }
        .onDisappear { model.stopFinding() }
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
            Text("Looking for Macs running Shepherd on this network…")
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
            Image(systemName: yes ? "checkmark" : "xmark")
                .font(.shSans(AppLayout.fleetGetsGlyphSize, .semibold))
                .foregroundStyle(yes ? Color.sh.done : Color.sh.textTertiary)
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
