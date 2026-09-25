// Home track's screens.
extension FixtureCatalog {
    static var home: [FixtureScreen] {
        [
            FixtureScreen(name: "home"),
            FixtureScreen(name: "home-empty", hosts: []),
            FixtureScreen(name: "needsyou", routes: [.home(.needsYou)]),
            FixtureScreen(name: "automations", routes: [.home(.automations)]),
            FixtureScreen(name: "more", routes: [.home(.more)]),
        ]
    }
}
