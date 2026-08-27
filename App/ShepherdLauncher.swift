import SwiftUI
import ShepherdApp

// Entry-point shim: delegates to `ShepherdMacApp.main()` so SwiftUI owns the
// App instance (required for @NSApplicationDelegateAdaptor / @StateObject to
// be lifecycle-managed; forwarding `body` from a hand-made instance is not).
@main
struct ShepherdLauncher {
    @MainActor
    static func main() {
        ShepherdMacApp.main()
    }
}
