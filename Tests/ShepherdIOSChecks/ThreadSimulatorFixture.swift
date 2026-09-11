import SwiftUI
import ShepherdCore

// This entry point is compiled only by run-simulator.sh, never into the shipped app.
enum HostTokenStore {
    static var token: String?
    static func read() throws -> String? { token }
    static func save(_ value: String) throws { token = value }
    static func remove() throws { token = nil }
}

@main
struct ThreadSimulatorFixture: App {
    @StateObject private var connection: HostConnection

    init() {
        let connection = HostConnection(defaults: UserDefaults(suiteName: "shepherd.thread.fixture")!)
        try! connection.save(name: "controlled fixture", host: "127.0.0.1",
                             port: ProcessInfo.processInfo.environment["FIXTURE_PORT"]!, token: "fixture-only")
        _connection = StateObject(wrappedValue: connection)
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                if let agent = connection.state.agents.first {
                    ThreadView(connection: connection, agentID: agent.id)
                } else {
                    Text(connection.phase.label)
                }
            }
                        .preferredColorScheme(ProcessInfo.processInfo.environment["FIXTURE_SCHEME"] == "light" ? .light : .dark)
            .task { connection.setForeground(true) }
        }
    }
}
