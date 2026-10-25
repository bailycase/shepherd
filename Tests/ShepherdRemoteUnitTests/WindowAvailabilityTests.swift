import Testing
@testable import ShepherdRemote

/// Where a window may open another, as the system allows it on the iOS 27.1 simulators: iPhone
/// Duo only on its inner display held upright, iPad in any window, other iPhones never.
@Suite("Window availability")
struct WindowAvailabilityTests {
    @Test(arguments: [
        // supportsMultipleWindows, hinge, regular width, taller than wide, opens
        (true, true, false, true, false),    // iPhone Duo closed (the outer display, 466×678)
        (true, true, false, false, false),   // iPhone Duo closed, sideways (678×466)
        (true, true, true, false, true),     // iPhone Duo open or half open, upright (951×669)
        (true, true, true, true, false),     // iPhone Duo open or half open, sideways (669×951)
        (false, false, true, false, false),  // another iPhone, a Pro Max in landscape
        (true, false, false, true, true),    // iPad, a narrow Split View window
        (true, false, true, false, true),    // iPad, landscape
    ])
    func onlyAnUprightInnerDisplayOpensWindowsOnAPhone(supports: Bool, hinge: Bool, regularWidth: Bool, tall: Bool, opens: Bool) {
        #expect(WindowAvailability.canOpenWindows(supportsMultipleWindows: supports, hinge: hinge,
                                                  regularWidth: regularWidth, tallWindow: tall) == opens)
    }
}
