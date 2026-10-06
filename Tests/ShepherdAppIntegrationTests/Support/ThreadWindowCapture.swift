import AppKit
import CoreML
import Vision
import Darwin
import Testing

// macOS 27's Vision GPU backend can fail to register its compute graph under test.
extension VNRecognizeTextRequest {
    func useCPUForTests() throws {
        revision = VNRecognizeTextRequestRevision2
        for (stage, devices) in try supportedComputeStageDevices {
            if let cpu = devices.first(where: { if case .cpu = $0 { true } else { false } }) {
                setComputeDevice(cpu, for: stage)
            }
        }
    }
}

/// WindowServer pixels without forcing a redraw. Capture only windows owned by this process.
/// The public CoreGraphics function is deprecated but remains available at runtime.
@MainActor
enum ThreadWindowCapture {
    static func image(_ window: NSWindow) throws -> CGImage {
        let id = CGWindowID(window.windowNumber)
        let info = try #require((CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first)
        #expect(info[kCGWindowOwnerPID as String] as? Int == Int(getpid()))
        try #require(info[kCGWindowOwnerPID as String] as? Int == Int(getpid()))
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let symbol = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"))
        let capture = unsafeBitCast(symbol, to: Capture.self)
        return try #require(capture(.null, CGWindowListOption.optionIncludingWindow.rawValue, id,
                                    CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue())
    }
}
