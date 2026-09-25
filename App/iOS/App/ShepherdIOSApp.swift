import SwiftUI

@main
struct ShepherdIOSApp: App {
    @State private var app = MobileApp.live()

    var body: some Scene {
        WindowGroup {
            MobileRoot(app: app)
        }
    }
}
