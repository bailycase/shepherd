import Foundation
import Testing
import ShepherdCore
@testable import ShepherdProtocol

/// Fleet ▸ Check on the wire: every field decodes with a default, a report is cut to bounds, and the synced Ignore setting round-trips.
@Suite("Fleet check wire")
struct FleetCheckWireTests {
    static let mini = UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!

    @Test func anItemFromAnOlderOrNewerBuildDecodesWithDefaults() throws {
        let item = try JSONDecoder().decode(FleetCheckItem.self, from: Data(#"{"id":"need:node:22"}"#.utf8))
        #expect(item.name == "need:node:22" && item.state == .unknown && item.kind == .other && item.group == .system && item.subjects.isEmpty)
        // A group, state and kind this build doesn't know are read as the quiet ones, never an error.
        let newer = try JSONDecoder().decode(FleetCheckItem.self, from: Data(#"{"id":"x","group":"future","state":"future","kind":"future","value":"v"}"#.utf8))
        #expect(newer.group == .system && newer.state == .unknown && newer.kind == .other && newer.value == "v")
    }

    @Test func aReportAndAMacStateRoundTripAndAnOlderMacHasNone() throws {
        let report = RemoteSamples.fleetCheck
        let data = try JSONEncoder().encode(FleetMacState(hostID: Self.mini, check: report, checkAge: 3))
        let back = try JSONDecoder().decode(FleetMacState.self, from: data)
        #expect(back.check == report && back.checkAge == 3)
        let older = try JSONDecoder().decode(FleetMacState.self, from: Data(#"{"hostID":"\#(Self.mini.uuidString)"}"#.utf8))
        #expect(older.check == nil && older.checkAge == nil)
        // A Mac state with a report this build can't read keeps the rest of its state.
        let broken = try JSONDecoder().decode(FleetMacState.self, from: Data(#"{"hostID":"\#(Self.mini.uuidString)","check":{"items":"no"}}"#.utf8))
        #expect(broken.check?.items.isEmpty == true)
    }

    @Test func aReportIsCutToBoundsAndTakesNoUnknownPackageManager() {
        var items = (0..<300).map { FleetCheckItem(id: "need:x:\($0)", group: .needs, name: "x\n\($0)", state: .warn, value: String(repeating: "v", count: 400)) }
        items.append(FleetCheckItem(id: "need:x:1", group: .needs, name: "duplicate", state: .ok, value: ""))
        items.append(FleetCheckItem(id: "", group: .needs, name: "no id", state: .ok, value: ""))
        let cut = FleetCheckReport(items: items, packageManager: "rm -rf").sanitized()
        #expect(cut.items.count == FleetCheckReport.limits.items)
        #expect(cut.items.allSatisfy { $0.value.count <= FleetCheckReport.limits.text && !$0.name.contains("\n") })
        #expect(Set(cut.items.map(\.id)).count == cut.items.count)
        #expect(cut.packageManager == "")
        #expect(FleetCheckReport(packageManager: "nix").sanitized().packageManager == "nix")
        #expect(FleetCheckReport(packageManager: "brew").sanitized().packageManager == "brew")
    }

    @Test func onlyAProviderThatDoesntAnswerLacksAModelsPlacement() {
        let report = FleetCheckReport(items: [
            FleetCheckItem(id: "models", group: .access, name: "Model sign-ins", state: .warn, value: "muse can’t start", kind: .provider, subjects: ["muse"]),
            FleetCheckItem(id: "need:node:22", group: .needs, name: "node 22", state: .warn, value: "Missing", kind: .tool),
            FleetCheckItem(id: "disk", group: .system, name: "Free disk", state: .warn, value: "38 GB", kind: .disk)])
        #expect(report.lacks == [.provider("muse")])
        #expect(FleetCheckReport(items: [FleetCheckItem(id: "models", group: .access, name: "m", state: .ok, value: "All answer", kind: .provider, subjects: ["muse"])]).lacks.isEmpty)
    }

    @Test func attentionLeavesOutWhatWasSetAside() {
        let report = RemoteSamples.fleetCheck
        #expect(report.attention().map(\.id) == ["need:node:22", "tool:muse"])
        #expect(report.attention(ignoring: ["tool:muse"]).map(\.id) == ["need:node:22"])
    }

    // MARK: Ignore on <Mac>

    @Test func theIgnoreSettingIsOneUnitPerMacWithTheIdsAsJSON() throws {
        var settings = HostSettings()
        settings.apply(.fleetCheckIgnore(hostID: Self.mini, ids: ["tool:muse", "disk", "disk"]))
        let unit = FleetCheckIgnoreSetting.unit(hostID: Self.mini)
        #expect(unit == "setting:fleet.checkIgnore.00000000-0000-0000-0000-0000000000f2")
        #expect(FleetCheckIgnoreSetting.hostID(unit: unit) == Self.mini)
        #expect(FleetCheckIgnoreSetting.values(in: settings) == [unit: #"["disk","tool:muse"]"#])
        #expect(FleetCheckIgnoreSetting.ignored(for: Self.mini, in: settings) == ["disk", "tool:muse"])
        let change = try #require(FleetCheckIgnoreSetting.change(hostID: Self.mini, fromJSON: #"["disk"]"#))
        #expect(change == .fleetCheckIgnore(hostID: Self.mini, ids: ["disk"]))
        #expect(FleetCheckIgnoreSetting.change(hostID: Self.mini, fromJSON: "{}") == nil)
        #expect(FleetCheckIgnoreSetting.hostID(unit: "setting:fleet.weight.\(Self.mini.uuidString.lowercased())") == nil)
        #expect(FleetCheckIgnoreSetting.hostID(unit: "setting:fleet.checkIgnore.not-a-host") == nil)
        #expect(change.capability == RemoteProtocol.fleetCheckCapability)
    }

    @Test func settingNothingAsideRemovesTheEntryAndAnOlderSettingsFileHasNone() throws {
        var settings = HostSettings()
        settings.apply(.fleetCheckIgnore(hostID: Self.mini, ids: ["disk"]))
        settings.apply(.fleetCheckIgnore(hostID: Self.mini, ids: []))
        #expect(settings.fleetCheckIgnores.isEmpty && FleetCheckIgnoreSetting.values(in: settings).isEmpty)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(HostSettings())) as? [String: Any])
        object["fleetCheckIgnores"] = nil
        let older = try JSONDecoder().decode(HostSettings.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.fleetCheckIgnores.isEmpty)
    }

    // MARK: Fix threads

    @Test func aFixThreadsItemsDecodeWithADefaultAndAreWrittenOnlyWhenSet() throws {
        let plain = FleetUserThread(spaceID: SpaceID(rawValue: "s"), task: "Do it")
        #expect(!String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("fixes"))
        let fixing = FleetUserThread(spaceID: SpaceID(rawValue: "s"), task: "Fix it", host: Self.mini.uuidString, fixes: ["need:node:22"])
        #expect(try JSONDecoder().decode(FleetUserThread.self, from: JSONEncoder().encode(fixing)) == fixing)
        let record = FleetDispatchRecord(kind: .userThread, parentHostID: Self.mini, parentHostName: "x", title: "t", task: "t", repoKey: "k", fixes: ["disk"], createdAt: 1)
        #expect(try JSONDecoder().decode(FleetDispatchRecord.self, from: JSONEncoder().encode(record)).fixes == ["disk"])
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object["fixes"] = nil
        #expect(try JSONDecoder().decode(FleetDispatchRecord.self, from: JSONSerialization.data(withJSONObject: object)).fixes.isEmpty)
    }

    @Test func aProvidersModelsAreNotPlacedWhereItCantStart() {
        let ok = FleetPlacement.Mac(hostID: UUID(), name: "This Mac", isLocal: true, hasRepo: true)
        let broken = FleetPlacement.Mac(hostID: Self.mini, name: "Mac mini", hasRepo: true, lacks: [.provider("muse")])
        #expect(FleetPlacement.provider(ofModel: "muse/model-a") == "muse")
        #expect(FleetPlacement.provider(ofModel: "model-a") == nil && FleetPlacement.provider(ofModel: nil) == nil)
        #expect(broken.problems(needsXcode: false, provider: "muse") == ["muse models"])
        #expect(broken.problems(needsXcode: false, provider: "anthropic").isEmpty && broken.problems(needsXcode: false).isEmpty)
        // Named: refused with the reason. Auto: left out. Another provider's thread goes there as before.
        #expect(FleetPlacement.place(host: "Mac mini", macs: [ok, broken], provider: "muse") == .refuse(code: FleetDispatchCode.hostNotReady, detail: "muse models"))
        if case .refuse = FleetPlacement.place(host: nil, macs: [broken], provider: "muse") {} else { Issue.record("Auto placed a muse thread where muse can't start") }
        #expect(FleetPlacement.place(host: "Mac mini", macs: [ok, broken], provider: "anthropic") == .place(hostID: Self.mini, reasons: [FleetPlacementReason(.named)]))
    }
}
