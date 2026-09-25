// Home track's settings and hosts screens.
extension FixtureCatalog {
    static var settings: [FixtureScreen] {
        [
            FixtureScreen(name: "settings", routes: [.settings(.root)], tab: .settings),
            FixtureScreen(name: "appearance", routes: [.settings(.appearance)], tab: .settings),
            FixtureScreen(name: "hosts", routes: [.settings(.hosts)], tab: .settings),
            FixtureScreen(name: "host", routes: [.settings(.hosts), .settings(.host(FixtureData.studio))], tab: .settings),
            FixtureScreen(name: "host-offline", routes: [.settings(.hosts), .settings(.host(FixtureData.laptop))], tab: .settings),
            FixtureScreen(name: "hosts-refused", hosts: FixtureData.refusingLaptop(), routes: [.settings(.hosts)], tab: .settings),
            FixtureScreen(name: "host-refused", hosts: FixtureData.refusingLaptop(),
                          routes: [.settings(.hosts), .settings(.host(FixtureData.laptop))], tab: .settings),
            FixtureScreen(name: "addhost", routes: [.settings(.hosts), .settings(.host(nil))], tab: .settings),
            FixtureScreen(name: "addhost-sheet", presented: .settings(.host(nil))),
        ]
    }
}

extension FixtureData {
    /// The given hosts (the usual ones by default), with the laptop up but refusing the phone's token.
    static func refusingLaptop(_ hosts: [FixtureHostData] = hosts()) -> [FixtureHostData] {
        hosts.map { host in
            var host = host
            if host.id == laptop {
                host.online = true
                host.refusesToken = true
            }
            return host
        }
    }
}
