// Search track's screens.
extension FixtureCatalog {
    static var search: [FixtureScreen] {
        [
            FixtureScreen(name: "search", routes: [.search(.search(query: ""))]),
        ]
    }
}
