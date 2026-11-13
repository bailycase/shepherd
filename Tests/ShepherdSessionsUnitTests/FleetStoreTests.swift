import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions

/// What a host keeps of a fleet (identity, peers) and the code window of a Mac that joins.
@Suite("Fleet store")
struct FleetStoreTests {
    static let start = Date(timeIntervalSince1970: 1_000)

    // MARK: Identity

    @Test func aHostMakesItsIdentityOnceAndKeepsIt() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("fleet")
        let first = try FleetIdentity.loadOrCreate(in: folder, now: Self.start)
        let again = try FleetIdentity.loadOrCreate(in: folder, now: Self.start.addingTimeInterval(9_999))
        #expect(again == first)
        #expect(first.createdAt == 1_000_000)
    }

    @Test func theFleetFolderAndItsFilesArePrivate() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("fleet")
        _ = try FleetIdentity.loadOrCreate(in: folder)
        try FleetPeers().save(to: folder)
        func mode(_ url: URL) -> mode_t { var info = stat(); _ = stat(url.path, &info); return info.st_mode & 0o777 }
        #expect(mode(folder) == 0o700)
        #expect(mode(folder.appendingPathComponent("identity.json")) == 0o600)
        #expect(mode(folder.appendingPathComponent("peers.json")) == 0o600)
    }

    @Test func aDamagedIdentityIsAnErrorNeverANewMac() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("fleet")
        let original = try FleetIdentity.loadOrCreate(in: folder)
        try Data("{".utf8).write(to: folder.appendingPathComponent("identity.json"))
        #expect(throws: (any Error).self) { try FleetIdentity.loadOrCreate(in: folder) }
        _ = original
    }

    // MARK: Peers

    static func record(_ name: String, token: String? = "t", hash: String? = FleetProtocol.hash("theirs"), paired: Double = 10) -> FleetPeerRecord {
        FleetPeerRecord(hostID: UUID(), name: name, addresses: [FleetAddress(host: "192.168.1.40", port: 7434)], myToken: token,
                        peerTokenHash: hash, pairedAt: paired)
    }

    @Test func peersRoundTripThroughTheirFile() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var peers = FleetPeers()
        let mini = Self.record("Mac mini"), studio = Self.record("Mac Studio", paired: 20)
        peers.upsert(mini)
        peers.upsert(studio)
        try peers.save(to: dir)
        #expect(try FleetPeers.load(from: dir) == peers)
        #expect(try FleetPeers.load(from: dir).record(mini.hostID)?.addresses == [FleetAddress(host: "192.168.1.40", port: 7434)])
    }

    /// New persisted fields decode with defaults, so a file from before them loads.
    @Test func aPeerFromAnOlderFileDecodesWithDefaults() throws {
        let id = UUID()
        let json = #"{"peers":[{"hostID":"\#(id.uuidString)","name":"Mac mini","pairedAt":5}]}"#
        let peers = try JSONDecoder().decode(FleetPeers.self, from: Data(json.utf8))
        let record = try #require(peers.record(id))
        #expect(record.kind == .mac && record.addresses.isEmpty && record.myToken == nil && record.peerTokenHash == nil)
        #expect(!record.revoked && record.introduce.isEmpty && !record.isLinkable)
        #expect(try FleetPeers.load(from: try makeTempDirectory()) == FleetPeers(), "no file is no peers")
    }

    @Test func aPeerIsLinkableOnlyWithATokenAndAnAddress() {
        var record = Self.record("Mac mini")
        #expect(record.isLinkable)
        record.myToken = nil
        #expect(!record.isLinkable)
        record.myToken = "t"
        record.addresses = []
        #expect(!record.isLinkable)
        record.addresses = [FleetAddress(host: "h", port: 1)]
        record.revoked = true
        #expect(!record.isLinkable)
    }

    @Test func aPeerIsKnownByItsTokenHashAndNeverByAnother() {
        var peers = FleetPeers()
        let mini = Self.record("Mac mini", hash: FleetProtocol.hash("mini-token"))
        let studio = Self.record("Mac Studio", hash: FleetProtocol.hash("studio-token"))
        peers.upsert(mini)
        peers.upsert(studio)
        #expect(peers.authenticate(token: "mini-token") == mini.hostID)
        #expect(peers.authenticate(token: "studio-token") == studio.hostID)
        #expect(peers.authenticate(token: "other") == nil)
        #expect(peers.authenticate(token: "") == nil)
        // The hash is what is kept: presenting the hash itself is no good.
        #expect(peers.authenticate(token: FleetProtocol.hash("mini-token")) == nil)
    }

    @Test func removingAPeerClearsItsTokensAndKeepsATombstone() throws {
        var peers = FleetPeers()
        let mini = Self.record("Mac mini", hash: FleetProtocol.hash("mini-token"), paired: 10)
        peers.upsert(mini)
        let removed = peers.revoke(mini.hostID, at: 50)
        #expect(removed)
        let gone = try #require(peers.record(mini.hostID))
        #expect(gone.revoked && gone.revokedAt == 50 && gone.myToken == nil && gone.peerTokenHash == nil)
        #expect(peers.members.isEmpty && peers.tombstones.count == 1)
        #expect(peers.authenticate(token: "mini-token") == nil, "its token is refused once it is removed")
        let again = peers.revoke(mini.hostID, at: 60)
        #expect(!again, "already removed: nothing changes")
    }

    /// News of a removal older than a pairing made since changes nothing; a Mac never heard of is remembered as removed.
    @Test func aStaleRemovalDoesNotUndoANewerPairing() {
        var peers = FleetPeers()
        let rejoined = Self.record("Mac mini", paired: 100)
        peers.upsert(rejoined)
        let stale = peers.revoke(rejoined.hostID, at: 50)
        #expect(!stale)
        #expect(peers.members.count == 1)
        let stranger = UUID()
        let heard = peers.revoke(stranger, at: 70)
        #expect(heard)
        #expect(peers.record(stranger)?.revoked == true)
    }

    // MARK: Join window

    @Test func aRightCodeIsAcceptedWithSpacesOrDashes() {
        var (window, code) = FleetJoinWindow.open(now: Self.start)
        #expect(code.count == FleetProtocol.codeLength && code.allSatisfy(\.isNumber))
        let spaced = "\(code.prefix(3)) \(code.suffix(3))"
        let result = window.attempt(spaced, now: Self.start.addingTimeInterval(1))
        #expect(result == .accepted)
    }

    @Test func theCodeIsNeverKeptOnlyItsHash() {
        let (window, code) = FleetJoinWindow.open(now: Self.start)
        #expect(window.codeHash == FleetProtocol.hash(code) && window.codeHash != code)
        #expect(!String(describing: window).contains(code), "the window's description doesn't hold the code")
    }

    @Test func fiveWrongTriesCloseTheWindowEvenForTheRightCode() {
        var (window, code) = FleetJoinWindow.open(now: Self.start)
        let wrong = code == "000000" ? "111111" : "000000"
        var results: [FleetJoinWindow.Attempt] = []
        for _ in 0..<FleetProtocol.maxCodeAttempts { results.append(window.attempt(wrong, now: Self.start)) }
        #expect(results == [.wrong(attemptsLeft: 4), .wrong(attemptsLeft: 3), .wrong(attemptsLeft: 2), .wrong(attemptsLeft: 1), .lockedOut])
        let right = window.attempt(code, now: Self.start)
        #expect(right == .lockedOut)
    }

    @Test func aCodeExpiresAfterFiveMinutes() {
        var (window, code) = FleetJoinWindow.open(now: Self.start)
        #expect(window.expiresAt == Self.start.addingTimeInterval(5 * 60))
        let justInTime = window.attempt(code, now: Self.start.addingTimeInterval(5 * 60 - 1))
        #expect(justInTime == .accepted)
        var (late, lateCode) = FleetJoinWindow.open(now: Self.start)
        let tooLate = late.attempt(lateCode, now: Self.start.addingTimeInterval(5 * 60))
        #expect(tooLate == .expired)
    }

    @Test func codesAreNotTheSameTwice() {
        let codes = Set((0..<50).map { _ in FleetJoinWindow.open().code })
        #expect(codes.count > 40, "fifty codes from a secure generator should hardly ever repeat")
    }

    // MARK: Advertising

    @Test func theBonjourRecordCarriesTheNameAndAHashOfTheIDOnly() {
        let id = UUID()
        let txt = FleetDiscovery.txtRecord(hostID: id, name: "Mac mini", build: "412")
        let entries = Self.entries(of: txt)
        #expect(entries == ["v=1", "id=\(FleetProtocol.advertisedIDHash(id))", "name=Mac mini", "build=412"])
        #expect(!String(decoding: txt, as: UTF8.self).contains(id.uuidString))
    }

    @Test func longNamesAreCutOnACharacterBoundary() {
        let name = String(repeating: "é", count: 80)
        let cut = FleetDiscovery.instanceName(name)
        #expect(cut.utf8.count <= 63 && cut.allSatisfy { $0 == "é" })
        #expect(FleetDiscovery.truncated("abc", bytes: 10) == "abc")
    }

    static func entries(of txt: Data) -> [String] {
        var entries: [String] = []
        var index = txt.startIndex
        while index < txt.endIndex {
            let length = Int(txt[index])
            let start = txt.index(after: index)
            let end = txt.index(start, offsetBy: length)
            entries.append(String(decoding: txt[start..<end], as: UTF8.self))
            index = end
        }
        return entries
    }
}
