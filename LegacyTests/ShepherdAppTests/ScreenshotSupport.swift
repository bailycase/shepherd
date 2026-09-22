import AppKit
import SwiftUI
import Testing

/// Renders `view` in a real window with an explicit appearance and writes
/// `<SHEPHERD_NATIVE_SCREENSHOT_DIR>/<name>.png`. A no-op (after layout) when the variable is
/// unset, so screenshot tests still exercise the view in normal runs.
@MainActor
func renderScreenshot<V: View>(_ view: V, size: CGSize, name: String, dark: Bool, settle: Duration = .milliseconds(250)) async throws {
    _ = NSApplication.shared
    // Far off every screen: the window must be ordered in for SwiftUI to lay out and draw,
    // but never where it could flash over someone's work.
    let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
    host.appearance = window.appearance
    window.contentView = host
    window.orderBack(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    try await Task.sleep(for: settle)
    host.layoutSubtreeIfNeeded()
    guard let dir = ProcessInfo.processInfo.environment["SHEPHERD_NATIVE_SCREENSHOT_DIR"] else { return }
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
}
