import SwiftUI
import Testing
@testable import ShepherdApp

@Suite("Component gallery", .serialized)
@MainActor
struct ComponentGalleryTests {
    @Test(arguments: [false, true])
    func galleryRendersInBothAppearances(dark: Bool) async throws {
        try await renderScreenshot(ComponentGallery(), size: CGSize(width: 1440, height: 1320),
                                   name: "components-\(dark ? "dark" : "light")", dark: dark)
    }
}
