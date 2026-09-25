// Thread track's screens (thread and composer).
extension FixtureCatalog {
    static var thread: [FixtureScreen] {
        [
            FixtureScreen(name: "thread", routes: [.thread(FixtureData.ref(FixtureData.preview))]),
            FixtureScreen(name: "running", routes: [.thread(FixtureData.ref(FixtureData.extensions))]),
            FixtureScreen(name: "question", routes: [.thread(FixtureData.ref(FixtureData.dock))]),
            FixtureScreen(name: "queue", routes: [.thread(FixtureData.ref(FixtureData.extensions))]),
        ]
    }
}
