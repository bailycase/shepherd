import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

extension ListPerformanceTests {
    /// The terminal panel's card (GXTerminal) and the toolbar capsule holding a running app's chip cast their
    /// lift shadows from fills alone: two shadows each (near and far), none cast from a subtree, so a
    /// terminal redrawing inside the card or the chip hovering never redraws a shadow.
    @Test func theTerminalCardAndTheToolbarCapsuleCastTheirShadowsFromFillsAlone() throws {
        let key = AppKey(scope: .space(SpaceID()), name: "Web app")
        let item = QuickApps.Item(key: key, app: AppDefinition(name: "Web app", command: "npm run dev", quickAction: true),
                                  status: .running, port: 3000)
        let card = CGRect(x: 28, y: 300, width: 600, height: 280)
        let geometry = TerminalPanelGeometry(thread: CGRect(x: 0, y: 0, width: 660, height: 300), leaves: [], card: card,
                                             tabBar: nil, content: nil, tabs: [], selected: nil)
        let window = OffscreenWindow(size: CGSize(width: 660, height: 600), dark: true, ZStack(alignment: .topLeading) {
            TerminalPanelCard(geometry: geometry)
            SHToolbarCapsule {
                ThreadAppsButton(apps: QuickApps(space: "payments", items: [item]), run: { _ in }, stop: { _ in }, restart: { _ in },
                                 output: { _ in }, edit: {})
            }
            .padding(SH.Space.m)
        })
        defer { window.close() }
        ListPerf.settle(window)
        let shadows = ListPerf.shadowedLayers(in: window)
        #expect(shadows.count == 4, "\(shadows.map(\.layer))")
        #expect(shadows.allSatisfy { $0.subtree == 1 }, "a shadow over content: \(shadows.map(\.subtree))")
    }
}
