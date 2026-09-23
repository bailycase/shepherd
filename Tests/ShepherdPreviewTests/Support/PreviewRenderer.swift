import AppKit
import Foundation
import ShepherdTestSupport
import SwiftUI
import Testing
import Vision
@testable import ShepherdApp

/// Where previews go: `$SHEPHERD_PREVIEW_DIR/<surface>-<light|dark>.png`. Every preview test
/// is gated on the variable so plain `swift test` never renders.
enum Preview {
    static let directory = ProcessInfo.processInfo.environment["SHEPHERD_PREVIEW_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    static let enabled = directory != nil
    /// The live use case needs the user's real `pi`; the fixture previews put a stub first on
    /// PATH, so the two never run in one process.
    static let liveModel = ProcessInfo.processInfo.environment["SHEPHERD_LIVE_MODEL"]?.isEmpty == false

    /// Renders `content` in light and then dark, each in its own off-screen window (borderless,
    /// ordered to the back, never key), once `ready` holds, and writes both PNGs.
    @MainActor
    static func render<V: View>(
        _ surface: String,
        size: CGSize,
        ready: @escaping @MainActor () -> Bool = { true },
        afterReady: @MainActor () -> Void = {},
        untilGone text: String? = nil,
        @ViewBuilder _ content: () -> V
    ) async throws {
        let directory = try #require(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let host = NSHostingView(rootView: content().environment(\.colorScheme, dark ? .dark : .light))
            host.appearance = window.appearance
            window.contentView = host
            window.orderBack(nil)
            defer { window.orderOut(nil); window.contentView = nil }

            try await eventuallyOnMain("\(surface) to be ready to render", timeout: .seconds(30)) {
                host.layoutSubtreeIfNeeded()
                return ready()
            }
            afterReady()
            if let text {
                // Async work the test cannot observe (a sheet's own probes): wait until its
                // placeholder text is no longer on screen.
                try await eventuallyOnMain("'\(text)' to leave \(surface)", timeout: .seconds(30), poll: .milliseconds(200)) {
                    !Self.shows(text, in: host)
                }
            }
            // Let appear transitions (≤ 0.2s in DESIGN.md) finish before capturing.
            for _ in 0..<4 {
                try await Task.sleep(for: .milliseconds(60))
                window.layoutIfNeeded()
            }
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(distinctColors(bitmap) >= 8, "\(surface) rendered (nearly) blank")
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(surface)-\(dark ? "dark" : "light").png"))
        }
    }

    /// Whether `text` is legible in the rendered view.
    @MainActor
    static func shows(_ text: String, in host: NSView) -> Bool {
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return false }
        let request = VNRecognizeTextRequest()
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).contains { $0.topCandidates(1).first?.string.localizedCaseInsensitiveContains(text) == true }
    }

    /// Distinct colors on a coarse grid: a blank or single-fill render has one or two.
    private static func distinctColors(_ bitmap: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        let step = max(1, min(bitmap.pixelsWide, bitmap.pixelsHigh) / 60)
        for x in stride(from: 0, to: bitmap.pixelsWide, by: step) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: step) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let r = UInt32(color.redComponent * 255), g = UInt32(color.greenComponent * 255), b = UInt32(color.blueComponent * 255)
                seen.insert(r << 16 | g << 8 | b)
            }
        }
        return seen.count
    }
}

/// Process-wide isolation for previews that build real app surfaces: a scratch support
/// directory (extensions and themes install there, never into the user's), a scratch ZDOTDIR,
/// and a fake `pi` first on PATH that answers `--list-models` with a fixed catalog and
/// otherwise runs the scripted stub. Previews run only when explicitly requested, so this is
/// installed once and left in place for the process.
enum PreviewEnvironment {
    nonisolated(unsafe) private static var installed = false
    private static let lock = NSLock()

    static let models = """
    provider   model                      context  max-out  thinking  images
    anthropic  claude-opus-4-5            200K     64K      yes       yes
    anthropic  claude-sonnet-4-5          1M       64K      yes       yes
    anthropic  claude-haiku-4-5           200K     64K      yes       yes
    openai     gpt-5                      400K     128K     yes       yes
    google     gemini-2.5-pro             1M       64K      yes       yes
    """

    static func install() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        let root = try makeScratchDirectory("previews")
        let bin = root.appendingPathComponent("bin"), zdotdir = root.appendingPathComponent("zdotdir"), support = root.appendingPathComponent("support")
        for dir in [bin, zdotdir, support] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try FileManager.default.createFile(atPath: root.appendingPathComponent("models.txt").path, contents: Data(models.utf8))
        let pi = bin.appendingPathComponent("pi")
        try """
        #!/bin/sh
        if [ "$1" = "--list-models" ]; then cat '\(root.appendingPathComponent("models.txt").path)'; exit 0; fi
        exec /usr/bin/env python3 '\(StubPi.path)'
        """.write(to: pi, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pi.path)
        setenv("PATH", "\(bin.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")", 1)
        setenv("ZDOTDIR", zdotdir.path, 1)
        setenv("SHEPHERD_SUPPORT_DIR", support.path, 1)
        installed = true
    }
}
