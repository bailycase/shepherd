import CoreGraphics
import Foundation
import ImageIO
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import Testing
import UniformTypeIdentifiers
@testable import DesignSurfaceKit

/// Opt-in: renders every board of a real canvas (`SHEPHERD_DESIGN_CANVAS`, a folder holding
/// `project/canvas.json`) at its canvas size, with Google Fonts, and reports what each drew. With
/// `SHEPHERD_PREVIEW_DIR` set, each board's snapshot goes to `<dir>/design-canvas/<board>.png` for
/// comparing by eye against the canvas's own thumbnails.
@MainActor
@Suite(.mainActorExclusive(timeLimit: .seconds(30 * 60)),
       .enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_DESIGN_CANVAS"] != nil, "set SHEPHERD_DESIGN_CANVAS to a design folder"))
struct DesignCanvasFidelityCheck {
    @Test func everyBoardOfTheCanvasBootsAndDrawsItsFrame() async throws {
        let environment = ProcessInfo.processInfo.environment
        let folder = URL(fileURLWithPath: try #require(environment["SHEPHERD_DESIGN_CANVAS"]), isDirectory: true)
        let index = try DesignIndex.decode(Data(contentsOf: folder.appendingPathComponent("project/canvas.json")))
        let output = environment["SHEPHERD_PREVIEW_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("design-canvas", isDirectory: true)
        }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }

        let surface = DesignSurface(designID: DesignID(rawValue: "canvas"), folder: folder, network: .googleFonts)
        var report: [String] = []
        var failed = 0
        for path in index.order {
            guard let board = index.boards[path] else { continue }
            // A canvas copied without every board lists files it doesn't hold: nothing to draw.
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("project/" + path.rawValue).path) else {
                report.append("\(path.rawValue): no file")
                continue
            }
            let size = CGSize(width: board.w, height: board.h)
            let view = DesignBoardView(surface: surface, board: path, size: size)
            var problems: [DesignBoardProblem] = []
            view.onEvent = { event in if case .problem(let problem) = event { problems.append(problem) } }
            do {
                let drew = try await view.load()
                var line = "\(path.rawValue): canvas \(Int(size.width))×\(Int(size.height)), drew \(Int(drew.width))×\(Int(drew.height))"
                if drew != size { line += " (differs)" }
                for problem in problems { line += "\n    \(problem)" }
                report.append(line)
                if !problems.isEmpty { failed += 1 }
                if let output {
                    let image = try await view.snapshot()
                    try Self.writePNG(image, to: output.appendingPathComponent(path.stem.replacingOccurrences(of: "/", with: "_") + ".png"))
                }
            } catch {
                failed += 1
                report.append("\(path.rawValue): did not boot: \(error)")
            }
        }
        let text = report.joined(separator: "\n")
        print(text)
        if let output { try Data(text.utf8).write(to: output.appendingPathComponent("report.txt")) }
        #expect(failed == 0, "\(failed) boards failed or reported problems")
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
