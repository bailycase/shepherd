import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import UIKit

// The sidebar's comings and goings over the overview and a thread (DuoOpenOverview, DuoOpenThread, DuoOpenSidePane, iPadSidebar): what the
// window shows once the sidebar is pressed away and back, by the system's Show sidebar and by the card's own. Nothing is left behind
// the card, and no second button is drawn. Run them posed (`run-simulator.sh -f open`) or on an iPad.
extension FixtureCatalog {
    static var chrome: [FixtureScreen] {
        let fleet = HomeFixtureData.fleet()
        let settle: @MainActor (MobileApp) async -> Void = { app in await HomeFeed.of(app.hosts).refresh() }
        return [
            // The sidebar away, the overview alone.
            FixtureScreen(name: "chrome-overview-away", hosts: fleet, prepare: { app in
                await settle(app)
                await OverviewOpenCheck.hideSidebar(app)
            }),
            // The sidebar brought back by the card's own binding over the overview.
            FixtureScreen(name: "chrome-overview-back", hosts: fleet, prepare: { app in
                await settle(app)
                await OverviewOpenCheck.hideSidebar(app)
                app.navigator.padColumns = .all
                try? await Task.sleep(for: .seconds(2))
            }),
            // The system's Show sidebar pressed, as a finger does.
            FixtureScreen(name: "chrome-overview-system", hosts: fleet, prepare: { app in
                await settle(app)
                SidebarAutomationsCheck.enableAccessibility()
                await OverviewOpenCheck.hideSidebar(app)
                try? await Task.sleep(for: .seconds(1))
                if let toggle = SidebarAutomationsCheck.all.first(where: { $0.accessibilityLabel?.lowercased().contains("sidebar") == true }) {
                    FixtureCheck.report("FIXTURE CHECK ok: pressing \(toggle.accessibilityLabel ?? "") -> \(toggle.accessibilityActivate())")
                } else {
                    FixtureCheck.report("FIXTURE CHECK FAILED: no sidebar button among \(SidebarAutomationsCheck.labels())")
                }
                try? await Task.sleep(for: .seconds(2))
            }),
        ]
    }
}
