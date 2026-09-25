// Review track's screens.
extension FixtureCatalog {
    static var review: [FixtureScreen] {
        [
            FixtureScreen(name: "review", routes: [.thread(FixtureData.ref(FixtureData.preview)),
                                                   .review(.changes(FixtureData.ref(FixtureData.preview), file: nil))]),
            FixtureScreen(name: "diff", routes: [.thread(FixtureData.ref(FixtureData.preview)),
                                                 .review(.diff(FixtureData.ref(FixtureData.preview), path: "App/iOS/ThreadView.swift"))]),
        ]
    }
}
