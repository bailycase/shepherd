import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Settings ▸ Fleet (FleetSettings): the Macs paired with this one, and the two ways to add one.
/// Sync, dispatch and code rows.
struct FleetSettings: View {
    var model: FleetSettingsModel
    /// Agents keep running (and Fleet keeps its links) with Shepherd quit: the background service
    /// runs the host. False or unknown: the host is the app's own child, and Fleet stops at Quit.
    var serviceKeepsRunning: Bool?
    /// Serve this Mac: keeps the listener open whether or not a Mac or a device is paired.
    var serve: FleetServe?
    /// Macs this app was a client of before Fleet was how Macs connect: each is a row under Macs to add to the fleet or dismiss.
    var notInFleet: [FleetNotInFleetMac] = []
    var dismissNotInFleet: (UUID) -> Void = { _ in }
    /// Settings ▸ Fleet ▸ Code (slice 4c); nil draws no Code group.
    var code: FleetCodeSettings?
    /// The Dispatch group's controls (`AppSettings`, synced across the fleet); nil draws none.
    var dispatch: FleetDispatchControls?

    @State var excluding = false
    @State private var adding = false
    @State private var joining = false
    @State private var addingDevice = false
    @State private var removing: FleetMacRow?
    @State private var addingFromClient: FleetNotInFleetMac?
    @State private var revoking: FleetDeviceRow?

    static let explanation = "Your Macs work as one. Settings, instructions, skills, extensions, MCP servers and sign-ins are the same on every Mac, and any Mac can take a thread. Changes sync on their own, including each save in a linked extension folder."
    /// FleetSettings' footer, reworded: Shepherd adds no TLS, so the fleet runs over the person's own network.
    static let footnote = "Macs pair once, with a code shown on the other Mac. Shepherd doesn't encrypt fleet traffic, so keep the fleet on a network you trust."
    static let devicesFootnote = "iPhones, iPads and Mac apps connect to every Mac in the fleet with a token of their own. They hold no sign-ins and can't pair or remove Macs. Any Mac can revoke one."
    /// Serve this Mac's footnote: nothing listens on a fresh Mac, so the switch says when it does.
    static let serveFootnote = "This Mac starts listening on its own once another Mac or a device is paired, or while a code is showing. Turn this on to listen all the time. Your own network is the transport."
    static let stopsAtQuit = "The background service is off, so Fleet stops when you quit Shepherd. Turn it on in System Settings ▸ General ▸ Login Items."

    var body: some View {
        SettingsPage(title: "Fleet", subtitle: model.syncLine.map { [$0.lead, $0.tail].compactMap { $0 }.joined(separator: " · ") }) {
            if let dispatch { FleetDispatchGroup(controls: dispatch) }
            codeGroup
            macs
            devices
            serving
        }
        .shAnimation(.list, value: model.rows.map(\.id))
        .shAnimation(.list, value: notInFleet.map(\.id))
        .shAnimation(.disclosure, value: serve?.problem)
        .shAnimation(.content, value: serve?.status)
        .shAnimation(.list, value: model.deviceRows.map(\.id))
        .shAnimation(.disclosure, value: model.problem)
        .shAnimation(.disclosure, value: model.deviceProblem)
        .task {
            await model.refresh()
            if model.incomingLink != nil { adding = true }
        }
        // A pairing link opened from outside the app: Add a Mac opens with it filled in (`FleetPairSheet`).
        .onChange(of: model.incomingLink) { if model.incomingLink != nil { adding = true } }
        .sheet(isPresented: $adding) {
            FleetPairSheet(model: model) { adding = false }
        }
        .sheet(item: $addingFromClient) { mac in
            FleetPairSheet(model: model, candidate: mac.found, onAdded: { dismissNotInFleet(mac.id) }) { addingFromClient = nil }
        }
        .sheet(isPresented: $joining) {
            FleetJoinView(model: model) { joining = false }
        }
        .sheet(isPresented: $excluding) {
            FleetExcludesSheet(spaces: code?.spaces ?? [], save: { code?.setExcludes($0, $1) }) { excluding = false }
        }
        .sheet(isPresented: $addingDevice) {
            FleetDeviceSheet(model: model) { addingDevice = false }
        }
        .sheet(item: $revoking) { row in
            DialogSheet(
                title: "Revoke \(row.title)?",
                subtitle: "Every Mac in the fleet refuses it and ends its connection now. Pair it again with a code to bring it back.",
                actions: [
                    DialogAction("Cancel", kind: .cancel) { revoking = nil },
                    DialogAction("Revoke", kind: .destructive) {
                        revoking = nil
                        Task { await model.revokeDevice(row.id) }
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
        SettingsGroup(title: "Where threads run") {
            SettingsRow(title: "Auto", subtitle: "New threads go to the Mac with the most room") {
                SettingsSwitch(label: "Auto", isOn: controls.autoDispatch)
            }
            SettingsRow(title: "Threads can send work to other Macs") {
                SettingsSwitch(label: "Threads can send work to other Macs", isOn: controls.threadsCanSend)
            }
            SettingsRow(title: "At most per thread") {
                SHPopupMenu(Self.capTitle(controls.threadCap.wrappedValue), minWidth: 0) {
                    Picker("At most per thread", selection: controls.threadCap) {
                        ForEach(Array(HostSettings.fleetThreadCapRange), id: \.self) { Text(Self.capTitle($0)).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .accessibilityLabel("At most per thread")
            }
            SettingsRow(title: "On battery") {
                SHPopupMenu(controls.batteryCountsHalf.wrappedValue ? "Counts half" : "Counts full", minWidth: 0) {
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
    /// The Macs of the fleet, the Macs this app used to be a client of, and the two ways to add one.
    @ViewBuilder fileprivate var macs: some View {
        SettingsGroup(title: "Macs", footnote: serviceKeepsRunning == true ? nil : Self.stopsAtQuit, links: [
            SettingsLink("Join a fleet") { joining = true },
            SettingsLink("Add a Mac") { model.openPairing(); adding = true },
        ]) {
            ForEach(model.rows) { row in
                FleetMacRowView(row: row) { removing = row }
                    .shTransition(.list)
            }
            ForEach(notInFleet) { mac in
                FleetMacRowView(row: mac.row, remove: {}, add: { model.openPairing(); addingFromClient = mac },
                                dismiss: { dismissNotInFleet(mac.id) })
                    .shTransition(.list)
            }
            if let problem = model.problem {
                SettingsRow(title: "", problem: problem) { EmptyView() }
                    .shTransition(.disclosure)
            }
        }
    }

    /// This Mac's listener, which a Mac or a device connects to: it opens on its own once one is paired or a code shows, and this keeps it open.
    @ViewBuilder fileprivate var serving: some View {
        if let serve {
            SettingsGroup(title: "Serve this Mac", footnote: "Your own network is the transport.") {
                SettingsRow(title: "Listener", subtitle: serve.status, problem: serve.problem, problemHelp: serve.problemDetail) {
                    SettingsSwitch(label: "Listener", isOn: serve.isOn)
                }
            }
        }
    }

    /// Phones and tablets paired as clients.
    @ViewBuilder fileprivate var devices: some View {
        SettingsGroup(title: "Phones and tablets", links: model.devicesReady && model.snapshot.port != nil
                      ? [SettingsLink("Add a device") { addingDevice = true }] : []) {
            if model.deviceRows.isEmpty {
                SettingsRow(title: "No devices", subtitle: "Add an iPhone or iPad. It reads and sends on every Mac in the fleet.") { EmptyView() }
                    .shTransition(.list)
            }
            ForEach(model.deviceRows) { row in
                FleetDeviceRowView(row: row) { revoking = row }
                    .shTransition(.list)
            }
            if let problem = model.deviceProblem {
                SettingsRow(title: "", problem: problem) { EmptyView() }
                    .shTransition(.disclosure)
            }
        }
    }
}

/// What Settings ▸ Fleet says about Serve this Mac's listener.
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
        SettingsRow(title: row.title, subtitle: row.detail, dot: row.connected ? .on : .off) {
            Button("Revoke", action: revoke)
                .buttonStyle(.sh(.secondary, size: .s))
                .accessibilityLabel("Revoke \(row.title)")
        }
    }
}

/// One Mac of the list: its dot, its name over where it is, and Remove for the Macs paired with this one.
struct FleetMacRowView: View {
    let row: FleetMacRow
    let remove: () -> Void
    /// A Mac this app was a client of: Add to fleet… and Dismiss take Remove's place.
    var add: (() -> Void)?
    var dismiss: (() -> Void)?

    var body: some View {
        SettingsRow(title: row.title, subtitle: row.detail, dot: dot) {
            HStack(spacing: SH.Space.s) {
                if let add, let dismiss {
                    Button("Add to fleet…", action: add)
                        .buttonStyle(.sh(.secondary, size: .s))
                        .accessibilityLabel("Add \(row.title) to the fleet")
                    Button("Dismiss", action: dismiss)
                        .buttonStyle(.sh(.secondary, size: .s))
                        .accessibilityLabel("Dismiss \(row.title)")
                } else if row.hostID != nil {
                    Button("Remove", action: remove)
                        .buttonStyle(.sh(.secondary, size: .s))
                        .accessibilityLabel("Remove \(row.title)")
                }
            }
        }
    }

    private var dot: SHRowDot {
        switch row.state {
        case .thisMac, .connected: .on
        case .connecting: .warn
        case .offline, .notInFleet: .off
        }
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

/// A Mac this app was a client of: its row, and where it was as a Mac Add a Mac can start from.
struct FleetNotInFleetMac: Identifiable, Equatable {
    let id: UUID
    let row: FleetMacRow
    let found: FoundMac

    init(id: UUID, name: String, host: String, port: UInt16) {
        self.id = id
        row = .notInFleet(id: id, name: name, host: host, port: port)
        found = FoundMac(id: id.uuidString, name: name, address: host, port: port)
    }
}
