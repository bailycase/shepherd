import Foundation
import Testing
import ShepherdRemote

/// Replays what the scroll-stability case recorded (`python3 scripts/validate.py --case scroll-stability` writes `mac/frames.json`:
/// per display frame the clip's offset, the document's height, the clip's size, the realized rows, the motion, the fixture's actions
/// and every write the app logged) through the owner, and writes down what the owner would have decided beside what the code did.
///
/// It runs only when `SHEPHERD_SCROLL_REPLAY` names a `frames.json`; set `SHEPHERD_SCROLL_REPLAY_OUT` to keep the per-frame report
/// (JSON lines). The checks that always hold are asserted: nothing automatic while the reader moves, and one decision per frame.
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
                var decision = ThreadScrollOwner.Decision.none
                if wasHidden {
                    wasHidden = false
                    decision = owner.mount()
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
                let read = owner.read(Self.reading(frame), intent: intent)
                if decision == .none { decision = read }
                if intent != .idle, decision != .none, intent != .programmatic { automaticWhileMoving += 1 }
                lines.append(Line(
                    scenario: name, frame: index, intent: "\(intent)", mode: Self.describe(owner.mode),
                    decision: Self.describe(decision), ownerFollows: owner.follows, codeFollows: frame.following,
                    codeWrites: frame.events.filter { $0.caller.hasPrefix("thread.write.") && $0.kind != "fixture" && $0.kind != "layout" }.map(\.caller),
                    clipMovedByCode: frame.events.filter { $0.caller == "NSClipView.bounds" && $0.detail != "fixture.clip.scroll" }.count,
                    requests: requests))
            }
        }
        #expect(automaticWhileMoving == 0, "the owner decided to write while the reader moved")
        #expect(lines.count > 600)
        if let out = ProcessInfo.processInfo.environment["SHEPHERD_SCROLL_REPLAY_OUT"] {
            let encoder = JSONEncoder()
            let text = try lines.map { String(decoding: try encoder.encode($0), as: UTF8.self) }.joined(separator: "\n")
            try text.write(toFile: out, atomically: true, encoding: .utf8)
        }
    }
}
