// Subagents track's screens.
extension FixtureCatalog {
    static var subagents: [FixtureScreen] {
        [
            FixtureScreen(name: "subagents", routes: [.thread(FixtureData.ref(FixtureData.preview)),
                                                      .subagents(.list(FixtureData.ref(FixtureData.preview)))]),
        ]
    }
}
