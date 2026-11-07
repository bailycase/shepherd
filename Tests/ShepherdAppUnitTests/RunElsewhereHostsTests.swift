import Foundation
import ShepherdCore
import Testing
@testable import ShepherdApp

/// Run on another host's list: where the thread runs now is marked and never offered, a host offers itself only with a Space of the
/// task's Space's name, hosts the Project does not allow are left out, and an offline paired host is shown but never offered.
@Suite("Run on another host")
struct RunElsewhereHostsTests {
    let web = Space(name: "acme-web", path: "/w")
    let api = Space(name: "acme-api", path: "/a")
    let studio = ProjectHostReference.remote(hostID: UUID(), bindingID: UUID())
    let build = ProjectHostReference.remote(hostID: UUID(), bindingID: UUID())

    @Test func onlyAnotherHostWithTheSameSpaceIsOffered() {
        let options = [ProjectHostOption(reference: .local, name: "owner-mac", spaces: [web, api]),
                       ProjectHostOption(reference: studio, name: "studio", spaces: [Space(name: "acme-web", path: "/s")]),
                       ProjectHostOption(reference: build, name: "build-01", spaces: [api]),
                       ProjectHostOption(reference: .remote(hostID: UUID(), bindingID: UUID()), name: "old-host", spaces: nil)]
        let away = RunElsewhereHosts.Offline(id: UUID(), name: "horizon", lastSeen: Date(timeIntervalSince1970: 0))
        let rows = RunElsewhereHosts.rows(options: options, settings: .init(hostPolicy: .anyConnected), from: .local, spaceName: "acme-web",
                                          ownerName: "This Mac", running: { $0 == .local ? 2 : 0 }, offline: [away],
                                          now: Date(timeIntervalSince1970: 3 * 3_600))
        #expect(rows.map(\.name) == ["This Mac", "studio", "build-01", "old-host", "horizon"])
        #expect(rows.map(\.selectable) == [false, true, false, false, false])
        #expect(rows[0].detail == "Runs here now · 2 running" && rows[0].current)
        #expect(rows[1].detail == "Idle" && rows[1].space != nil)
        #expect(rows[2].detail == "No acme-web here · Idle")
        #expect(rows[3].detail.hasPrefix("Update Shepherd there"))
        #expect(rows[4].detail == "Unreachable · last seen 3h ago" && !rows[4].online)
    }

    @Test func aHostTheProjectDoesNotAllowIsLeftOut() {
        let options = [ProjectHostOption(reference: .local, name: "owner-mac", spaces: [web]),
                       ProjectHostOption(reference: studio, name: "studio", spaces: [web])]
        let rows = RunElsewhereHosts.rows(options: options, settings: .init(allowedHosts: [.local]), from: studio, spaceName: "acme-web",
                                          ownerName: "This Mac", running: { _ in nil }, offline: [])
        #expect(rows.map(\.name) == ["This Mac", "studio"], "the current host stays listed even when no longer allowed")
        #expect(rows.map(\.selectable) == [true, false])
        let narrowed = RunElsewhereHosts.rows(options: options, settings: .init(allowedHosts: [studio]), from: studio, spaceName: "acme-web",
                                              ownerName: "This Mac", running: { _ in nil }, offline: [])
        #expect(narrowed.map(\.name) == ["studio"])
    }
}
