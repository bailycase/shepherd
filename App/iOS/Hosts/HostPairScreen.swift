import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Add a Mac: pick a Mac Bonjour found, enter the code its Settings ▸ Fleet ▸ Add a device shows (or scan
/// its QR). The Mac pairs this device as a client of its whole fleet, with a token of its own that this
/// device keeps in the Keychain. There is no address and no token field: a Mac that isn't found is on
/// another network.
struct HostPairScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(\.dismiss) private var dismiss
    @Environment(MobileNavigator.self) private var navigator
    @State private var model: MobilePairing?
    @State private var scanning = false

    var body: some View {
        Group {
            if let model { PairForm(model: model, scanning: $scanning, dismiss: dismiss.callAsFunction) } else { Color.clear }
        }
        .background(Color.sh.bgWindow)
        .navigationTitle("Add a Mac")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Presented from Home or More, the screen is a sheet's root and needs its own way out.
            if navigator.presented?.route == .settings(.host(nil)) {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .task {
            let pairing = MobilePairing(hosts: hosts)
            MobilePairing.seed(pairing)
            model = pairing
            pairing.start()
        }
        .onDisappear { model?.stop() }
        .sheet(isPresented: $scanning) {
            PairScanner { text in model?.take(scanned: text) }
        }
    }
}

/// The form itself, from plain state so previews and checks can draw every phase.
struct PairForm: View {
    @Bindable var model: MobilePairing
    @Binding var scanning: Bool
    var canScan = PairScanner.isAvailable
    let dismiss: () -> Void

    var body: some View {
        Form {
            Section {
                if model.found.isEmpty {
                    HStack(spacing: SH.Space.s) {
                        ProgressView().controlSize(.small)
                        Text("Looking for Macs running Shepherd on this network…")
                    }
                    .font(.sh(.ui)).foregroundStyle(Color.sh.textTertiary)
                }
                ForEach(model.found) { mac in
                    PairMacRow(mac: mac, selected: model.mac?.id == mac.id) { model.picked = mac.id }
                }
            } header: {
                Text("1 · Pick the Mac").shSectionLabel()
            } footer: {
                Text("Open Shepherd on the Mac. Both need to be on the same local network.")
                    .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
            }
            Section {
                PairCodeField(code: $model.code)
                    .frame(maxWidth: .infinity)
                    .disabled(model.phase == .working)
                if canScan {
                    Button("Scan the code", systemImage: "qrcode.viewfinder") { scanning = true }
                        .disabled(model.phase == .working)
                }
            } header: {
                Text("2 · Enter the code it shows").shSectionLabel()
            } footer: {
                Text("On \(model.mac?.name ?? "the Mac"): Settings ▸ Fleet ▸ Add a device. The code lasts 5 minutes.")
                    .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
            }
            Section {
                gets
            } header: {
                Text("What this device gets").shSectionLabel()
            }
            Section {
                Button(action: pair) {
                    HStack {
                        Text(model.mac.map { "Add \($0.name)" } ?? "Add Mac")
                        if model.phase == .working { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(!model.ready)
            } footer: {
                status
            }
        }
        .listRowBackground(Color.sh.bgRaised)
        .font(.sh(.ui))
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .failed(let message):
            Text(message).font(.sh(.caption)).foregroundStyle(Color.sh.failed)
        case .paired(let names):
            Text("Added \(names.joined(separator: ", ")). It is paired with the whole fleet.")
                .font(.sh(.caption)).foregroundStyle(Color.sh.done)
        case .idle, .working:
            Text("Any Mac in the fleet can revoke this device.")
                .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
        }
    }

    private var gets: some View {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            getsRow(true, "Your threads on every Mac in the fleet: read them, send, start new ones and answer questions")
            getsRow(false, "No sign-ins and no settings. A device is a client, and can't pair or remove Macs.")
        }
        .font(.sh(.ui))
        .foregroundStyle(Color.sh.textSecondary)
    }

    private func getsRow(_ yes: Bool, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
            Image(systemName: yes ? "checkmark" : "xmark")
                .foregroundStyle(yes ? Color.sh.done : Color.sh.textTertiary)
                .accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func pair() {
        Task {
            await model.pair()
            if case .paired = model.phase { dismiss() }
        }
    }
}

/// A Mac Bonjour found: its name over its address, and a tick when chosen.
struct PairMacRow: View {
    let mac: FoundMac
    let selected: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(spacing: SH.Space.m) {
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    Text(mac.name).foregroundStyle(Color.sh.textPrimary)
                    Text(mac.address ?? "").font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary)
                }
                Spacer(minLength: SH.Space.m)
                if let version = mac.version {
                    Text("Shepherd \(version)").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                }
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(Color.sh.running).accessibilityHidden(true)
                }
            }
            .frame(minHeight: MobileLayout.twoLineRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mac.name), \(mac.address ?? "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Six boxes for the code, two groups of three. One text field holds the digits (the number pad, a
/// pasted code); the boxes only draw them.
struct PairCodeField: View {
    @Binding var code: String
    @FocusState private var focused: Bool

    var body: some View {
        let sh = Color.sh
        ZStack {
            HStack(spacing: SH.Space.s) {
                ForEach(0..<FleetProtocol.codeLength, id: \.self) { index in
                    let digits = Array(code)
                    Text(digits.indices.contains(index) ? String(digits[index]) : "")
                        .font(.shMono(SHTextStyle.display.size))
                        .foregroundStyle(sh.textPrimary)
                        .frame(width: MobileLayout.pairDigitWidth, height: MobileLayout.pairDigitHeight)
                        .background(sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                        .overlay {
                            RoundedRectangle(cornerRadius: SH.Radius.m)
                                .strokeBorder(focused && index == min(code.count, FleetProtocol.codeLength - 1) ? sh.running : sh.lineStrong)
                        }
                        .padding(.trailing, index == FleetProtocol.codeLength / 2 - 1 ? MobileLayout.pairDigitGroupGap - SH.Space.s : 0)
                }
            }
            .accessibilityHidden(true)
            TextField("Pairing code", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focused)
                .foregroundStyle(Color.clear)
                .tint(Color.clear)
                .opacity(0.01)
        }
        .fixedSize()
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }
}
