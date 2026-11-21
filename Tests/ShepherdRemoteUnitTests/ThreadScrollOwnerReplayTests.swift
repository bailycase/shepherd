import Foundation
import Testing
import ShepherdRemote

/// Replays what the scroll-stability case recorded (`python3 scripts/validate.py --case scroll-stability` writes `mac/frames.json`:
/// per display frame the clip's offset, the document's height, the clip's size, the realized rows, the motion, the fixture's actions
/// and every write the app logged) through the owner, and writes down what the owner would have decided beside what the code did.
///
/// It runs only when `SHEPHERD_SCROLL_REPLAY` names a `frames.json`; set `SHEPHERD_SCROLL_REPLAY_OUT` to keep the per-frame report
/// (JSON lines). Asserted: nothing automatic while the reader moves, no mount and reading deciding in one frame, and the scenarios' first decisions.
@Suite("Thread scroll owner: replay of the scroll-stability recording")
struct ThreadScrollOwnerReplayTests {
    struct Event: Decodable {
        var caller: String
        var kind: String?
        var detail: String?
    }

    struct Frame: Decodable {
        var hidden: Bool
        var first: String?
        var rows: [String: Double]
        var offset: Double?
        var documentHeight: Double?
        var clipSize: [Double]?
        var following: Bool
        var distance: Double
        var events: [Event]
        var motion: String
    }

    struct Line: Encodable {
        var scenario: String
        var frame: Int
        var intent: String
        var mode: String
        var decision: String
        var ownerFollows: Bool
        var codeFollows: Bool
        var codeWrites: [String]
        var clipMovedByCode: Int
        var requests: [String]
        /// What the mount at the top of the frame decided, apart from the reading's own decision.
        var mountDecision: String
    }

    static var path: String? { ProcessInfo.processInfo.environment["SHEPHERD_SCROLL_REPLAY"] }

    static func intent(_ motion: String) -> ThreadScrollOwner.Intent {
        switch motion {
        case "touching", "wheel": .touching
        case "coasting": .coasting
        case "programmatic": .programmatic
        default: .idle
        }
    }

    /// The clip's frame as a probe: the case records the distance the code computed, from which the bottom inset follows.
    static func reading(_ frame: Frame) -> ThreadScrollOwner.Reading {
        let content = frame.documentHeight ?? 0, offset = frame.offset ?? 0
        let size = frame.clipSize ?? [0, 0]
        let inset = frame.distance - content + offset + size[1]
        let probe = NativeScrollProbe(content: content, offset: offset, container: size[1] - inset, insetTop: 0, insetBottom: inset)
        return .init(probe: probe, width: size[0], topRow: frame.first, rows: frame.rows)
    }

    static func describe(_ mode: ThreadScrollOwner.Mode) -> String {
        switch mode {
        case .following: "following"
        case .pinned(let anchor): anchor.map { "pinned(\($0.row))" } ?? "pinned(nil)"
        case .jumping(let row): "jumping(\(row))"
        }
    }

    static func describe(_ decision: ThreadScrollOwner.Decision) -> String {
        switch decision {
        case .none: "none"
        case .land: "land"
        case .hold(let anchor): "hold(\(anchor.row)@\(anchor.offset))"
        case .reveal(let row): "reveal(\(row))"
        case .scroll(let row, let animated): "scroll(\(row),\(animated))"
        }
    }

    /// Every row the scenario ever realized, oldest first: `user-N` by N, its reply after it, the live reply last.
    static func order(_ frames: [Frame]) -> [String] {
        func key(_ id: String) -> (Int, Int, String) {
            let parts = id.split(separator: "/", omittingEmptySubsequences: false)
            let number = parts[0].split(separator: "-").last.flatMap { Int($0) } ?? Int.max
            return (parts[0].hasPrefix("stream") ? Int.max : number, parts.count, id)
        }
        return Set(frames.flatMap { $0.rows.keys }).sorted { key($0) < key($1) }
    }

    @Test(.enabled(if: path != nil, "SHEPHERD_SCROLL_REPLAY names a recorded frames.json"))
    func replay() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: try #require(Self.path)))
        let scenarios = try JSONDecoder().decode([String: [Frame]].self, from: data)
        var lines: [Line] = []
        var automaticWhileMoving = 0
        var collisions = 0
        for name in scenarios.keys.sorted() {
            let frames = scenarios[name] ?? []
            // A recording starts wherever its first scenario step left the reader: seed the owner the way a kept place would.
            let start = frames.first { !$0.hidden }
            let seed = start.flatMap { frame in
                frame.following ? ThreadScrollOwner.Mode.following
                    : .pinned(frame.first.flatMap { row in frame.rows[row].map { .init(row: row, offset: $0) } })
            } ?? .following
            var owner = ThreadScrollOwner(mode: seed)
            _ = owner.rowsChanged(Self.order(frames))
            var wasHidden = false
            for (index, frame) in frames.enumerated() {
                if frame.hidden {
                    wasHidden = true
                    continue
                }
                var requests: [String] = []
                var mount = ThreadScrollOwner.Decision.none
                if wasHidden {
                    wasHidden = false
                    mount = owner.mount()
                    requests.append("mount")
                }
                for event in frame.events {
                    switch event.caller {
                    case "fixture.stickyChunk", "fixture.streamChunk", "fixture.newTurn":
                        owner.contentArrived()
                        requests.append("output")
                    case "fixture.pageReply": requests.append("historyPage")
                    default: break
                    }
                }
                // The fixture's drag starts and ends inside one display frame, so the frame's own motion reads idle: the reader's
                // input in it still counts (the intent signal's `readerInput`).
                let input = frame.events.contains { $0.caller == "fixture.scrollInput" || $0.caller == "fixture.phase.interacting" }
                let intent = input ? .touching : Self.intent(frame.motion)
                let decision = owner.read(Self.reading(frame), intent: intent)
                // One decision per frame: a mount's and the reading's must not both ask for a write.
                if mount != .none, decision != .none { collisions += 1 }
                if intent != .idle, decision != .none || mount != .none, intent != .programmatic { automaticWhileMoving += 1 }
                lines.append(Line(
                    scenario: name, frame: index, intent: "\(intent)", mode: Self.describe(owner.mode),
                    decision: Self.describe(decision), ownerFollows: owner.follows, codeFollows: frame.following,
                    codeWrites: frame.events.filter { $0.caller.hasPrefix("thread.write.") && $0.kind != "fixture" && $0.kind != "layout" }.map(\.caller),
                    clipMovedByCode: frame.events.filter { $0.caller == "NSClipView.bounds" && $0.detail != "fixture.clip.scroll" }.count,
                    requests: requests, mountDecision: Self.describe(mount)))
            }
        }
        #expect(automaticWhileMoving == 0, "the owner decided to write while the reader moved")
        #expect(collisions == 0, "a mount and a reading decided in the same frame")
        // The scenarios' decisions, not only their absence while moving.
        let flick = lines.filter { $0.scenario == "flick-and-stop" }
        let detach = flick.firstIndex { !$0.ownerFollows }
        let firstWrite = flick.firstIndex { $0.decision != "none" }
        #expect(detach != nil && flick[detach!].intent != "idle", "the flick detaches while it moves")
        #expect(firstWrite != nil && firstWrite! > detach!, "the clamp is answered after the detach")
        #expect(firstWrite.map { flick[$0].decision } == "hold(stream-user@-24.0)", "the clamp is put back to where the reader left the row")
        #expect(firstWrite.map { flick[$0].intent } == "idle", "and only once the reader has let go")
        let history = lines.filter { $0.scenario == "page-older-history" && $0.decision != "none" }
        #expect(history.map(\.decision) == ["reveal(user-60)"], "the page's lost anchor is asked for once")
        #expect(lines.count > 600)
        if let out = ProcessInfo.processInfo.environment["SHEPHERD_SCROLL_REPLAY_OUT"] {
            let encoder = JSONEncoder()
            let text = try lines.map { String(decoding: try encoder.encode($0), as: UTF8.self) }.joined(separator: "\n")
            try text.write(toFile: out, atomically: true, encoding: .utf8)
        }
    }

    /// The flick-and-stop recording's numbers (its frames 3 to 8, the rows around the reader), as readings: a flick up inside the
    /// band, the view past it by frame 5, and at the end the document shrinks 504 pt and the clip clamps 369 pt, so the row the reader
    /// left at -24 sits at -159. Nothing is written while the reader moves; the one decision after it undoes the jump.
    @Test func theFlickClampIsUndoneByOneHoldAfterTheReaderLetsGo() {
        func reading(content: Double, offset: Double, rows: [String: Double], top: String) -> ThreadScrollOwner.Reading {
            let probe = NativeScrollProbe(content: content, offset: offset, container: 506, insetTop: 0, insetBottom: 134)
            return .init(probe: probe, width: 910, topRow: top, rows: rows)
        }
        var owner = ThreadScrollOwner()
        _ = owner.rowsChanged(["user-359", "stream-user", "stream-user/reply"])
        var decisions: [ThreadScrollOwner.Decision] = []
        decisions.append(owner.read(reading(content: 71392, offset: 70886, rows: ["stream-user": -159, "stream-user/reply": -94], top: "stream-user/reply"), intent: .idle))
        decisions.append(owner.read(reading(content: 71392, offset: 70886, rows: ["stream-user": -159, "stream-user/reply": -94], top: "stream-user/reply"), intent: .touching))
        decisions.append(owner.read(reading(content: 71392, offset: 70816, rows: ["stream-user": -89, "stream-user/reply": -24], top: "stream-user/reply"), intent: .coasting))
        #expect(owner.follows, "70 pt from the tail is still inside the band")
        decisions.append(owner.read(reading(content: 71392, offset: 70771, rows: ["stream-user": -44, "stream-user/reply": 21], top: "stream-user/reply"), intent: .coasting))
        #expect(!owner.follows, "115 pt, moving up with the layout as it was: detached while it moves")
        decisions.append(owner.read(reading(content: 71392, offset: 70751, rows: ["stream-user": -24, "stream-user/reply": 41], top: "stream-user"), intent: .coasting))
        #expect(owner.mode == .pinned(.init(row: "stream-user", offset: -24)))
        #expect(decisions.allSatisfy { $0 == .none }, "nothing is written while the reader moves: \(decisions)")
        // They let go, and layout (the shrink above the reader) clamped the clip: one decision, the row back where they left it.
        let clamped = reading(content: 70888, offset: 70382, rows: ["stream-user": -159, "stream-user/reply": -94], top: "stream-user/reply")
        #expect(owner.read(clamped, intent: .idle) == .hold(.init(row: "stream-user", offset: -24)))
    }
}
