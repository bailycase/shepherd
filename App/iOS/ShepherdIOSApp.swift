import SwiftUI

@main
struct ShepherdIOSApp: App {
    @StateObject private var connection = HostConnection()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            FleetView(connection: connection)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    // Inactive includes system dialogs. Only backgrounding drops the socket.
                    if phase == .active { connection.setForeground(true) }
                    if phase == .background { connection.setForeground(false) }
                }
        }
    }
}
