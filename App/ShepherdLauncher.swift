import SwiftUI
import ShepherdApp

// Entry-point shim: delegates to `ShepherdMacApp.main()` so SwiftUI owns the
// App instance (required for @NSApplicationDelegateAdaptor / @State to
// be lifecycle-managed; forwarding `body` from a hand-made instance is not).
// `--host` runs the headless session host instead, with no UI.
@main
struct ShepherdLauncher {
    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst().contains(ShepherdHost.argument) { ShepherdHost.main() }
        ShepherdMacApp.main()
    }
}
