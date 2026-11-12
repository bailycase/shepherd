import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Settings ▸ Fleet (FleetSettings): the Macs paired with this one, and the two ways to add one.
/// Only the parts that exist yet: sync and dispatch are here; the code rows arrive with the slice that builds them.
struct FleetSettings: View {
    var model: FleetSettingsModel
    /// Agents keep running (and Fleet keeps its links) with Shepherd quit: the background service
    /// runs the host. False or unknown: the host is the app's own child, and Fleet stops at Quit.
    var serviceKeepsRunning: Bool?
    /// Settings ▸ Experiments ▸ Fleet is on. Off: no Macs are paired into a fleet, but this Mac still serves
    /// (`serve`), takes iPhones and iPads by code and is a client of other Macs with a code (`clients`): what
    /// Remote did, without a pasted token.
    var enabled = true
    var serve: FleetServe?
    /// The Macs this app is a client of: with Fleet off, every one it holds; with Fleet on, those that aren't
    /// fleet peers (a Mac without Fleet, a host paired as a client).
    var clients: [FleetMacRow] = []
    var removeClient: (UUID) -> Void = { _ in }
    /// The Dispatch group's controls (`AppSettings`, synced across the fleet); nil draws none.
    var dispatch: FleetDispatchControls?

    @State private var adding = false
    @State private var joining = false
    @State private var addingDevice = false
    @State private var removing: FleetMacRow?
    @State private var removingClient: FleetMacRow?
    @State private var revoking: FleetDeviceRow?
    @State private var retiring = false

    static let explanation = "Your Macs work as one. Settings, instructions, skills, extensions, MCP servers and sign-ins are the same on every Mac, and any Mac can take a thread. Changes sync on their own, including each save in a linked extension folder."
    /// FleetSettings' footer, reworded: Shepherd adds no TLS, so the fleet runs over the person's own network.
    static let footnote = "Macs pair once, on the same local network, with a code shown on the other Mac. Shepherd doesn't encrypt fleet traffic, so keep the fleet on a network you trust."
    static let offExplanation = "Fleet is off. This Mac still serves its threads to your other Macs, iPhones and iPads, which connect with a code you show here. Turn Fleet on in Settings ▸ Experiments to make your Macs work as one."
    static let clientsFootnote = "Pair with the code the other Mac shows under Settings ▸ Fleet ▸ Add a device, on the same local network. Removing a Mac here only forgets it; revoke this Mac there to cut it off."
    static let devicesFootnote = "iPhones, iPads and Mac apps connect with a token of their own. They hold no sign-ins and can't pair or remove Macs. Revoke one here to cut it off."
    static let fleetDevicesFootnote = "iPhones, iPads and Mac apps connect to every Mac in the fleet with a token of their own. They hold no sign-ins and can't pair or remove Macs. Any Mac can revoke one."
    static let stopsAtQuit = "The background service is off, so Fleet stops when you quit Shepherd. Turn it on in System Settings ▸ General ▸ Login Items."

    var body: some View {
        SettingsPage(title: "Fleet", explanation: enabled ? Self.explanation : Self.offExplanation,
                     status: enabled ? model.syncLine.map { AnyView(FleetSyncLineView(line: $0)) } : nil) {
            if enabled, let dispatch { FleetDispatchGroup(controls: dispatch) }
            if enabled { macs } else { hosts }
            if enabled, !clients.isEmpty { otherHosts }
            devices
            if !enabled { serving }
        }
        .shAnimation(.list, value: model.rows.map(\.id))
        .shAnimation(.list, value: clients.map(\.id))
        .shAnimation(.disclosure, value: serve?.problem)
        .shAnimation(.content, value: serve?.status)
        .shAnimation(.list, value: model.deviceRows.map(\.id))
        .shAnimation(.disclosure, value: model.problem)
        .shAnimation(.disclosure, value: model.deviceProblem)
        .shAnimation(.disclosure, value: model.snapshot.devices?.sharedToken)
        .task { await model.refresh() }
        .sheet(isPresented: $adding) {
            FleetPairSheet(model: model, asClient: !enabled) { adding = false }
        }
        .sheet(isPresented: $joining) {
            FleetJoinView(model: model) { joining = false }
        }
        .sheet(isPresented: $addingDevice) {
            FleetDeviceSheet(model: model) { addingDevice = false }
        }
        .sheet(item: $revoking) { row in
            DialogSheet(
                title: "Revoke \(row.title)?",
                subtitle: (enabled ? "Every Mac in the fleet" : "This Mac") + " refuses it and ends its connection now. Pair it again with a code to bring it back.",
                actions: [
                    DialogAction("Cancel", kind: .cancel) { revoking = nil },
                    DialogAction("Revoke", kind: .destructive) {
                        revoking = nil
                        Task { await model.revokeDevice(row.id) }
                    },
                ])
        }
        .sheet(isPresented: $retiring) {
            DialogSheet(
                title: "Stop accepting the shared token?",
                subtitle: "Only devices and Macs with a token of their own connect after this. Anything still using the shared token, like an older iPhone, needs to be paired again with a code.",
                actions: [
                    DialogAction("Cancel", kind: .cancel) { retiring = false },
                    DialogAction("Stop accepting it", kind: .destructive) {
                        retiring = false
                        Task { await model.retireSharedToken() }
                    },
                ])
        }
        .sheet(item: $removingClient) { row in
            DialogSheet(
                title: "Remove \(row.title)?",
                subtitle: "This Mac forgets it and its threads leave the sidebar. The other Mac still lists this one under Devices until you revoke it there. Pair it again with a code to bring it back.",
                actions: [
                    DialogAction("Cancel", kind: .cancel) { removingClient = nil },
                    DialogAction("Remove", kind: .destructive) {
                        removingClient = nil
                        if let id = row.hostID { removeClient(id) }
                    },
                ])
        }
        .sheet(item: $removing) { row in
            DialogSheet(
                title: "Remove \(row.title) from the fleet?",
                subtitle: "Every Mac in the fleet drops it. It keeps what it already has here. Pair it again with a code to bring it back.",
                actions: [
                    DialogAction("Cancel", kind: .cancel) { removing = nil },
                    DialogAction("Remove", kind: .destructive) {
                        removing = nil
                        if let hostID = row.hostID { Task { await model.remove(hostID) } }
                    },
                ])
        }
    }
}

/// What Settings ▸ Fleet ▸ Dispatch changes, as bindings the caller makes over its settings.
struct FleetDispatchControls {
    var autoDispatch: Binding<Bool>
    var threadsCanSend: Binding<Bool>
    var threadCap: Binding<Int>
    var batteryCountsHalf: Binding<Bool>
}

/// Settings ▸ Fleet ▸ Dispatch (FleetSettings): how work moves between Macs on its own.
private struct FleetDispatchGroup: View {
    let controls: FleetDispatchControls

    static func capTitle(_ cap: Int) -> String { "\(cap) at a time" }

    var body: some View {
        SettingsGroup(title: "Dispatch") {
            SettingsRow(title: "Auto dispatch", subtitle: "New threads go to the Mac with the most room. You can still pick a Mac in the composer.") {
                SettingsSwitch(label: "Auto dispatch", isOn: controls.autoDispatch)
            }
            SettingsRow(title: "Threads can send work to other Macs",
                        subtitle: "A thread hands separate work to the Mac with room and wakes up with the result. Threads it sends can’t send more.") {
                SettingsSwitch(label: "Threads can send work to other Macs", isOn: controls.threadsCanSend)
            }
            SettingsRow(title: "At most per thread", subtitle: "Sent threads running at once, across every Mac.") {
                SHPopupMenu(Self.capTitle(controls.threadCap.wrappedValue)) {
                    Picker("At most per thread", selection: controls.threadCap) {
                        ForEach(Array(HostSettings.fleetThreadCapRange), id: \.self) { Text(Self.capTitle($0)).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .accessibilityLabel("At most per thread")
            }
            SettingsRow(title: "On battery", subtitle: "How a Mac running on battery counts when Shepherd picks one.") {
                SHPopupMenu(controls.batteryCountsHalf.wrappedValue ? "Counts half" : "Counts full") {
                    Picker("On battery", selection: controls.batteryCountsHalf) {
                        Text("Counts half").tag(true)
                        Text("Counts full").tag(false)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .accessibilityLabel("On battery")
            }
        }
    }
}

extension FleetSettings {
    /// The Macs of the fleet, and the two ways to add one.
    @ViewBuilder fileprivate var macs: some View {
        SettingsGroup(title: "Macs", footnote: serviceKeepsRunning == true ? Self.footnote : Self.footnote + " " + Self.stopsAtQuit) {
            ForEach(model.rows) { row in
                FleetMacRowView(row: row) { removing = row }
                    .shTransition(.list)
            }
            if let problem = model.problem {
                SettingsActionRow(leading: { SHInlineProblem(problem) }, actions: { EmptyView() })
                    .shTransition(.disclosure)
            } else if model.loaded, model.snapshot.port == nil {
                SettingsActionRow(leading: { SHInlineProblem(serve?.problem ?? "This Mac isn't serving, so no other Mac or device can reach it.", help: serve?.problemDetail) },
                                  actions: { EmptyView() })
                    .shTransition(.disclosure)
            }
            SettingsActionRow {
                Button("Join a fleet…") { joining = true }
                    .buttonStyle(.sh(.secondary))
                    .disabled(!model.loaded || model.snapshot.port == nil)
                Button("Add a Mac…") { model.openPairing(); adding = true }
                    .buttonStyle(.sh(.secondary))
                    .disabled(!model.loaded || model.snapshot.port == nil)
            }
        }
    }

    /// Fleet off: the Macs this app is a client of, and Add a Mac (a code, no address or token).
    @ViewBuilder fileprivate var hosts: some View {
        SettingsGroup(title: "Macs", footnote: Self.clientsFootnote) {
            if clients.isEmpty {
                SettingsRow(title: "No Macs yet", subtitle: "Add a Mac running Shepherd. Its threads appear in the sidebar under its name.") { EmptyView() }
                    .shTransition(.list)
            }
            ForEach(clients) { row in
                FleetMacRowView(row: row) { removingClient = row }
                    .shTransition(.list)
            }
            SettingsActionRow {
                Button("Add a Mac…") { model.openPairing(); adding = true }
                    .buttonStyle(.sh(.secondary))
            }
        }
    }

    /// Fleet on: hosts that aren't in the fleet, each with Remove.
    @ViewBuilder fileprivate var otherHosts: some View {
        SettingsGroup(title: "Other hosts", footnote: "Macs this one connects to as a client, outside the fleet.") {
            ForEach(clients) { row in
                FleetMacRowView(row: row) { removingClient = row }
                    .shTransition(.list)
            }
        }
    }

    /// Fleet off: this Mac's listener, which every client device connects to.
    @ViewBuilder fileprivate var serving: some View {
        if let serve {
            SettingsGroup(title: "Serve this Mac",
                          footnote: "Sessions run on this Mac. Your own network is the transport. The shared token that opened this Mac before devices had their own stays good until you stop accepting it under Devices.") {
                SettingsRow(title: "Listener", subtitle: serve.status, problem: serve.problem, problemHelp: serve.problemDetail) {
                    SettingsSwitch(label: "Listener", isOn: serve.isOn)
                }
            }
        }
    }

    /// The Devices group: phones, iPads and Mac apps paired as clients, and where the shared token stands.
    @ViewBuilder fileprivate var devices: some View {
        SettingsGroup(title: "Devices", footnote: enabled ? Self.fleetDevicesFootnote : Self.devicesFootnote) {
            if model.deviceRows.isEmpty {
                SettingsRow(title: "No devices", subtitle: enabled ? "Add an iPhone or iPad below. It reads and sends on every Mac in the fleet." : "Add an iPhone or iPad below. It reads and sends on this Mac.") { EmptyView() }
                    .shTransition(.list)
            }
            ForEach(model.deviceRows) { row in
                FleetDeviceRowView(row: row) { revoking = row }
                    .shTransition(.list)
            }
            if let shared = model.snapshot.devices?.sharedToken { sharedToken(shared) }
            if let problem = model.deviceProblem {
                SettingsActionRow(leading: { SHInlineProblem(problem) }, actions: { EmptyView() })
                    .shTransition(.disclosure)
            }
            SettingsActionRow {
                Button("Add a device…") { addingDevice = true }
                    .buttonStyle(.sh(.secondary))
                    .disabled(!model.devicesReady || model.snapshot.port == nil)
            }
        }
    }

    /// The shared token: still accepted, who is still on it, or retired.
    @ViewBuilder private func sharedToken(_ shared: FleetSharedTokenStatus) -> some View {
        if shared.retired {
            SettingsRow(title: "Shared token retired", subtitle: "Only devices and Macs with a token of their own connect to this Mac.") { EmptyView() }
                .shTransition(.disclosure)
        } else {
            SettingsRow(title: "Shared token",
                        subtitle: shared.waiting.isEmpty
                            ? "Every device has its own token. This Mac still accepts the one it used to share, which anyone on your network who has it can use."
                            : "This Mac still accepts the token it used to share, so older devices keep working. Each switches to its own the next time Shepherd opens on it.") {
                Button("Stop accepting it") { retiring = true }
                    .buttonStyle(.sh(.secondary))
                    .disabled(!model.devicesReady || !shared.waiting.isEmpty)
            }
            .shTransition(.disclosure)
            ForEach(shared.waiting) { client in
                SettingsRow(title: "Waiting for \(client.name)", subtitle: "Connected with the shared token and hasn't switched yet.") {
                    Button("Forget") { Task { await model.forgetWaiting(client.id) } }
                        .buttonStyle(.sh(.secondary))
                        .accessibilityLabel("Forget \(client.name)")
                }
                .shTransition(.list)
            }
        }
    }
}

/// What Settings ▸ Fleet says about the listener while Fleet is off (it is the page's only control then).
struct FleetServe {
    var isOn: Binding<Bool>
    var status: String
    var problem: String?
    var problemDetail: String?
}

/// One device of the list: its dot, its name over what it is, and Revoke.
struct FleetDeviceRowView: View {
    let row: FleetDeviceRow
    let revoke: () -> Void

    var body: some View {
        SettingsActionRow {
            HStack(spacing: SH.Space.l) {
                if row.connected {
                    SHStatusDot(.done, size: AppLayout.fleetDotSize)
                } else {
                    SHStatusDot(.idle, size: AppLayout.fleetDotSize)
                }
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    Text(row.title)
                        .font(.sh(.body, weight: .medium))
                        .foregroundStyle(Color.sh.textPrimary)
                    Text(row.detail)
                        .font(.sh(.ui))
                        .foregroundStyle(Color.sh.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .combine)
        } actions: {
            Button("Revoke", action: revoke)
                .buttonStyle(.sh(.secondary))
                .accessibilityLabel("Revoke \(row.title)")
        }
    }
}

/// One Mac of the list: its dot, its name over where it is, and Remove for the Macs paired with this one.
struct FleetMacRowView: View {
    let row: FleetMacRow
    let remove: () -> Void

    var body: some View {
        SettingsActionRow {
            HStack(spacing: SH.Space.l) {
                dot
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    Text(row.title)
                        .font(.sh(.body, weight: .medium))
                        .foregroundStyle(Color.sh.textPrimary)
                    Text(row.detail)
                        .font(.sh(.ui))
                        .foregroundStyle(Color.sh.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .combine)
        } actions: {
            if row.hostID != nil {
                Button("Remove", action: remove)
                    .buttonStyle(.sh(.secondary))
                    .accessibilityLabel("Remove \(row.title)")
            }
        }
    }

    @ViewBuilder private var dot: some View {
        switch row.state {
        case .thisMac: SHStatusDot(.done, size: AppLayout.fleetDotSize, color: Color.sh.lantern)
        case .connected: SHStatusDot(.done, size: AppLayout.fleetDotSize)
        case .connecting: SHStatusDot(.running, size: AppLayout.fleetDotSize)
        case .offline: SHStatusDot(.idle, size: AppLayout.fleetDotSize)
        }
    }
}

/// Settings ▸ Experiments ▸ Fleet's card (no board draws it: the others' pattern).
struct FleetExperimentCard: View {
    @Bindable var settings: AppSettings

    var body: some View {
        let sh = Color.sh
        HStack(alignment: .top, spacing: SH.Space.l + SH.Space.xxs) {
            RoundedRectangle(cornerRadius: SH.Radius.m)
                .fill(sh.lanternTint)
                .frame(width: AppLayout.experimentTileSize, height: AppLayout.experimentTileSize)
                .overlay {
                    SHGlyph.Settings.remoteConnection.image
                        .foregroundStyle(sh.lanternText)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text("Fleet")
                    .font(.shSans(AppLayout.experimentNameSize, .semibold))
                    .foregroundStyle(sh.textPrimary)
                Text("Pair your Macs, iPhones and iPads with a code and keep the Macs' background services linked. Replaces Remote in Settings. "
                     + "Turning this off ends the links and keeps the Macs you paired.")
                    .shText(size: AppLayout.experimentDescriptionSize, lineHeight: AppLayout.experimentDescriptionLineHeight)
                    .foregroundStyle(sh.textSecondary)
                    .frame(maxWidth: AppLayout.experimentDescriptionWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: SH.Space.xxl)
            SettingsSwitch(label: "Fleet", isOn: $settings.fleetEnabled)
        }
        .padding(.vertical, SH.Space.l + SH.Space.xxs)
        .padding(.horizontal, SH.Space.xl)
        .shCard(fill: sh.bgWindow, line: sh.lineStrong)
    }
}

/// The line under the page's explanation: a dot, where sync stands, and after a dot who is away (FleetSettings).
struct FleetSyncLineView: View {
    let line: FleetSyncLine

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: SH.Space.s) {
                dot
                text
            }
            .accessibilityElement(children: .combine)
            if let notice = line.notice {
                Text(notice)
                    .font(.sh(.ui))
                    .foregroundStyle(Color.sh.textTertiary)
            }
        }
    }

    private var text: some View {
        let sh = Color.sh
        return (line.lead.map { Text($0).foregroundStyle(sh.textSecondary) } ?? Text(""))
            + (line.lead != nil && line.tail != nil ? Text("  ·  ").foregroundStyle(sh.textTertiary) : Text(""))
            + (line.tail.map { Text($0).foregroundStyle(sh.textTertiary) } ?? Text(""))
    }

    @ViewBuilder private var dot: some View {
        switch line.tone {
        case .inSync: SHStatusDot(.done, size: AppLayout.fleetDotSize)
        case .catchingUp: SHStatusDot(.running, size: AppLayout.fleetDotSize)
        case .alone: SHStatusDot(.idle, size: AppLayout.fleetDotSize)
        }
    }
}
