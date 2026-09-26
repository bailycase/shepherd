import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

/// Boards for the Design tool's tests and previews: small self-contained pages in the Design
/// format (no fonts or images to fetch), sized like the skill's boards, and a canvas laying them
/// out as the skill does (80pt apart in a row, rows 120pt apart).
public enum DesignFixtures {
    public struct Board: Sendable {
        public let path: String
        public let title: String
        public let width: Int
        public let height: Int
        public let accent: String

        public init(path: String, title: String, width: Int, height: Int, accent: String) {
            self.path = path
            self.title = title
            self.width = width
            self.height = height
            self.accent = accent
        }
    }

    /// Three directions and a phone version of the first, as the skill draws them.
    public static let checkout: [Board] = [
        Board(path: "A.dc.html", title: "A · Funnel first", width: 1280, height: 800, accent: "#4f46e5"),
        Board(path: "B.dc.html", title: "B · Step table", width: 1280, height: 800, accent: "#0f766e"),
        Board(path: "C.dc.html", title: "C · Trend first", width: 1280, height: 800, accent: "#b45309"),
        Board(path: "A-phone.dc.html", title: "A · phone", width: 390, height: 844, accent: "#4f46e5"),
    ]

    /// `count` small boards in rows of `perRow` (the large-canvas fixture).
    public static func grid(_ count: Int, perRow: Int = 12, width: Int = 320, height: Int = 200) -> [Board] {
        let accents = ["#4f46e5", "#0f766e", "#b45309", "#be123c"]
        return (0..<count).map { index in
            Board(path: "Board\(index).dc.html", title: "Board \(index)", width: width, height: height,
                  accent: accents[index % accents.count])
        }
    }

    /// A board's whole file. `note` changes what it says (a rewrite).
    public static func source(_ board: Board, note: String = "") -> String {
        let phone = board.height > board.width
        let cards = (0..<(phone ? 2 : 3)).map { index in
            """
            <div style="flex: 1; background: #ffffff; border: 1px solid #e4e4ea; border-radius: 10px; padding: 14px">\
            <div style="font-size: 12px; color: #6b6b7b">Step \(index + 1)</div>\
            <div style="font-size: 22px; font-weight: 600; margin-top: 6px">\(90 - index * 23)%</div></div>
            """
        }.joined()
        let bars = (0..<5).map { index in
            """
            <div style="height: 18px; width: \(100 - index * 17)%; background: \(board.accent); opacity: \(1.0 - Double(index) * 0.15); border-radius: 4px"></div>
            """
        }.joined()
        return """
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><title>\(board.title)</title><script src="./support.js"></script></head>
        <body>
        <x-dc>
        <helmet><style>body{margin:0;font-family:-apple-system,system-ui,sans-serif}</style></helmet>
        <div style="width: \(board.width)px; height: \(board.height)px; box-sizing: border-box; padding: \(phone ? 20 : 32)px; background: #f6f6f9; color: #1c1c28; display: flex; flex-direction: column; gap: 18px">
        <div style="display: flex; align-items: center; gap: 12px"><div style="width: 28px; height: 28px; border-radius: 8px; background: \(board.accent)"></div><h1 style="margin: 0; font-size: 22px">Checkout funnel\(note.isEmpty ? "" : " · \(note)")</h1></div>
        <div style="display: flex; flex-direction: \(phone ? "column" : "row"); gap: 14px">\(cards)</div>
        <div style="flex: 1; background: #ffffff; border: 1px solid #e4e4ea; border-radius: 12px; padding: 20px; display: flex; flex-direction: column; gap: 12px">\(bars)</div>
        </div>
        </x-dc>
        <script type="text/x-dc" data-dc-script data-props='{"$preview":{"width":\(board.width),"height":\(board.height)}}'>
        class Component extends DCLogic { renderVals() { return {}; } }
        </script>
        </body>
        </html>
        """
    }

    /// A canvas_update listing `boards`: `perRow` to a row, 80pt apart, rows 120pt apart.
    public static func layout(_ boards: [Board], perRow: Int = 3) -> JSONValue {
        var entries: [String: JSONValue] = [:]
        var x = 0, y = 0, rowHeight = 0
        for (index, board) in boards.enumerated() {
            if index > 0, index % perRow == 0 {
                x = 0
                y += rowHeight + 120
                rowHeight = 0
            }
            entries[board.path] = .object(["x": .number(Double(x)), "y": .number(Double(y)), "w": .number(Double(board.width)),
                                           "h": .number(Double(board.height)), "title": .string(board.title)])
            x += board.width + 80
            rowHeight = max(rowHeight, board.height)
        }
        return .object(["boards": .object(entries), "order": .array(boards.map { .string($0.path) })])
    }

    /// Writes `boards` into `design` and lays them out.
    public static func draw(_ boards: [Board], in design: DesignID, on server: SessionServer, perRow: Int = 3) async throws {
        for board in boards {
            _ = try await server.writeDesignBoard(design, path: try DesignPath.validate(board.path), source: source(board))
        }
        _ = try await server.updateDesignIndex(design, patch: layout(boards, perRow: perRow))
    }
}
