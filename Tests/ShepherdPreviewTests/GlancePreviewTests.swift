import Foundation
import ShepherdUI
import SwiftUI
import Testing

/// The glance surfaces (GlanceWatch, GlanceFollow, GlanceIsland, GlanceLock, GlanceHome,
/// GlanceiPad) drawn from the boards' threads, light and dark. The Lock Screen's card and a
/// widget's corners are the system's: `frame` stands in for them.
@Suite("Glance previews", .serialized, .mainActorExclusive,
       .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR to render previews"))
@MainActor
struct GlancePreviewTests {
    static let now = Date()

    static func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    static let session = SHGlance.Session(piSessionID: "p", generation: "g")
    static let hosts: [SHGlance.Host] = [.init(name: "This Mac", online: true), .init(name: "build-01", online: true),
                                         .init(name: "horizon", online: false)]

    static let deploy = SHGlance.Item(
        host: "mac", agent: "deploy", title: "Deploy media stack", state: .needsYou, hostName: "This Mac", since: ago(2),
        tag: "question", question: "How should I handle Horizon’s uncommitted edits?",
        options: ["Compare first", "Clean checkout"], dialogID: "d1", session: session, queued: 1)
    static let funnel = SHGlance.Item(host: "build", agent: "funnel", title: "Checkout funnel events", state: .needsYou,
                                      hostName: "build-01", since: ago(1), tag: "retention?")
    static let dock = SHGlance.Item(host: "mac", agent: "dock", title: "Dock review pane", state: .needsYou,
                                    hostName: "This Mac", since: ago(0.5), tag: "approve plan")
    static let restyle = SHGlance.Item(
        host: "mac", agent: "restyle", title: "Restyle native UI", state: .running, hostName: "This Mac", since: ago(37.2),
        session: session, command: "swift test --filter NativeThreadPresentation",
        subagents: .init(running: 1, waiting: 1, done: 1), changes: .init(files: 6, added: 67, removed: 48), queued: 2,
        goal: "Match the thread view to the spec · working")
    static let investigate = SHGlance.Item(host: "mac", agent: "inv", title: "Investigate SwiftUI live preview", state: .running,
                                           hostName: "This Mac", since: ago(12), session: session, command: "Read PreviewHost.swift")
    static let plan = SHGlance.Item(host: "build", agent: "plan", title: "Plan shepherd extension", state: .running,
                                    hostName: "build-01", since: ago(8), session: session)
    static let refund = SHGlance.Item(host: "build", agent: "refund", title: "Add refund events", state: .running,
                                      hostName: "build-01", since: ago(3), session: session, command: "swift build")
    static let refundFailed = SHGlance.Item(host: "build", agent: "refund", title: "Add refund events", state: .failed,
                                            hostName: "build-01", since: ago(9), result: "Tests failed after the schema change.",
                                            changes: .init(files: 4, added: 112, removed: 9))
    static let restyleDone = SHGlance.Item(host: "mac", agent: "restyle", title: "Restyle native UI", state: .done,
                                           hostName: "This Mac", since: ago(0.2),
                                           result: "Restyled the native thread view to the spec; 14 of 14 presentation tests pass.",
                                           changes: .init(files: 6, added: 67, removed: 48))
    static let payButton = SHGlance.Item(host: "mac", agent: "pay", title: "Fix pay button jump", state: .done,
                                         hostName: "This Mac", since: ago(2), result: "Done. 3 files changed, tests pass.")
    static let payments = SHGlance.Item(host: "build", agent: "metrics", title: "Payments metrics", state: .done,
                                        hostName: "build-01", since: ago(14))

    static let fleet = SHGlance(items: [deploy, funnel, dock, restyle, investigate, plan, refund, payButton, payments],
                                hosts: hosts, updated: now)
    static let working = SHGlance(items: [restyle, investigate, plan, refund], hosts: hosts, updated: now)
    static let staleFleet = SHGlance(items: [restyle, investigate, plan, refund],
                                     hosts: [.init(name: "This Mac", online: false), .init(name: "build-01", online: true)],
                                     updated: ago(6))
    static let quiet = SHGlance(items: [], hosts: hosts, updated: now)

    /// The Lock Screen's card around a Live Activity's content.
    func card<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .padding(.vertical, SH.Space.l)
            .padding(.horizontal, SH.Space.xl)
            .frame(width: 361, alignment: .leading)
            .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// A widget's frame at its size.
    func widget<V: View>(_ width: CGFloat, _ height: CGFloat, @ViewBuilder _ content: () -> V) -> some View {
        content()
            .padding(SH.Space.l)
            .frame(width: width, height: height)
            .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    func buttons(_ item: SHGlance.Item, stale: Bool = false) -> some View {
        SHGlanceButtons(item.actions(stale: stale)) { SHGlanceButtonLabel($0) }
    }

    func page<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content().padding(SH.Space.xxl).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.sh.bgBase)
    }

    @Test func watch() async throws {
        try await Preview.render("glance-watch", size: CGSize(width: 1200, height: 260)) {
            page {
                HStack(alignment: .top, spacing: SH.Space.xxl) {
                    card { SHGlanceWatchCard(Self.working, stale: false, now: Self.now) { buttons($0) } }
                    card { SHGlanceWatchCard(Self.fleet, stale: false, now: Self.now) { buttons($0) } }
                    card { SHGlanceWatchCard(Self.staleFleet, stale: true, now: Self.now) { buttons($0, stale: true) } }
                }
            }
        }
    }

    @Test func follow() async throws {
        let cases: [(SHGlance.Item, Bool)] = [(Self.restyle, false), (Self.deploy, false), (Self.restyleDone, false),
                                              (Self.refundFailed, false), (Self.restyle, true)]
        try await Preview.render("glance-follow", size: CGSize(width: 1980, height: 260)) {
            page {
                HStack(alignment: .top, spacing: SH.Space.xl) {
                    ForEach(Array(cases.enumerated()), id: \.offset) { _, entry in
                        let glance = entry.1 ? Self.staleFleet : Self.fleet
                        card { SHGlanceFollowCard(entry.0, in: glance, stale: entry.1, now: Self.now) { buttons($0, stale: entry.1) } }
                    }
                }
            }
        }
    }

    /// The island is black in both appearances: compact, minimal, and expanded.
    @Test func island() async throws {
        let black = Color.black
        func pill<V: View>(@ViewBuilder _ content: () -> V) -> some View {
            content().padding(.horizontal, SH.Space.l).frame(width: 250, height: 37).background(black, in: Capsule())
        }
        func expanded(_ item: SHGlance.Item, _ glance: SHGlance) -> some View {
            VStack(alignment: .leading, spacing: SH.Space.m) {
                HStack {
                    SHGlanceIslandLeading(item, stale: false)
                    Spacer()
                    SHGlanceIslandTrailing(glance, follow: item, expanded: true, stale: false, now: Self.now)
                }
                SHGlanceIslandBody(item, in: glance, stale: false, now: Self.now) { item in
                    SHGlanceButtons(item.actions) { SHGlanceButtonLabel($0, island: true) }
                }
            }
            .padding(.vertical, 20).padding(.horizontal, 24)
            .frame(width: 371, alignment: .leading)
            .background(black, in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        }
        try await Preview.render("glance-island", size: CGSize(width: 1300, height: 520)) {
            page {
                HStack(alignment: .top, spacing: SH.Space.xxl) {
                    VStack(spacing: SH.Space.l) {
                        pill { HStack { SHGlanceIslandMark(.running, stale: false); Spacer(); SHGlanceIslandTrailing(Self.working, stale: false, now: Self.now) } }
                        pill { HStack { SHGlanceIslandMark(.running, stale: false); Spacer(); SHGlanceIslandTrailing(Self.working, follow: Self.restyle, stale: false, now: Self.now) } }
                        pill { HStack { SHGlanceIslandMark(.needsYou, stale: false); Spacer(); SHGlanceIslandTrailing(Self.fleet, stale: false, now: Self.now) } }
                        pill { HStack { SHGlanceIslandMark(.done, stale: false); Spacer(); SHGlanceIslandTrailing(Self.fleet, follow: Self.restyleDone, stale: false, now: Self.now) } }
                        pill { HStack { SHGlanceIslandMark(.running, stale: true); Spacer(); SHGlanceIslandTrailing(Self.staleFleet, stale: true, now: Self.now) } }
                        HStack(spacing: SH.Space.s) {
                            Circle().fill(black).frame(width: 37, height: 37).overlay(SHGlanceIslandMinimal(.needsYou, stale: false))
                            Circle().fill(black).frame(width: 37, height: 37).overlay(SHGlanceIslandMinimal(.running, stale: false))
                        }
                    }
                    VStack(spacing: SH.Space.l) {
                        expanded(Self.restyle, Self.working)
                        expanded(Self.deploy, Self.fleet)
                    }
                    expanded(Self.restyleDone, Self.fleet)
                }
            }
        }
    }

    @Test func homeWidgets() async throws {
        try await Preview.render("glance-home", size: CGSize(width: 1180, height: 820)) {
            page {
                VStack(alignment: .leading, spacing: SH.Space.xl) {
                    HStack(alignment: .top, spacing: SH.Space.xl) {
                        widget(158, 158) { SHGlanceSmall(Self.fleet.lead, in: Self.fleet, stale: false, now: Self.now) }
                        widget(158, 158) { SHGlanceSmall(Self.restyle, in: Self.fleet, stale: false, now: Self.now) }
                        widget(158, 158) { SHGlanceSmall(nil, in: Self.quiet, stale: false, now: Self.now) }
                        widget(338, 158) { SHGlanceList(Self.fleet, rows: SHGlanceMetrics.mediumRows, stale: false, now: Self.now) }
                    }
                    HStack(alignment: .top, spacing: SH.Space.xl) {
                        widget(338, 354) { SHGlanceList(Self.fleet, rows: SHGlanceMetrics.largeRows, done: true, header: "All work", stale: false, now: Self.now) }
                        VStack(spacing: SH.Space.xl) {
                            widget(338, 158) { SHGlanceList(Self.quiet, rows: SHGlanceMetrics.mediumRows, stale: false, now: Self.now) }
                            widget(338, 158) { SHGlanceList(Self.staleFleet, rows: SHGlanceMetrics.mediumRows, stale: true, now: Self.now) }
                        }
                        VStack(alignment: .leading, spacing: SH.Space.xl) {
                            HStack(spacing: SH.Space.l) {
                                SHGlanceCircular(Self.fleet).frame(width: 72, height: 72)
                                SHGlanceCircular(Self.working).frame(width: 72, height: 72)
                            }
                            SHGlanceRectangular(Self.fleet, stale: false, now: Self.now).frame(width: 172, height: 76)
                            Text(Self.fleet.inline).font(.sh(.ui))
                        }
                    }
                }
            }
        }
    }

    @Test func iPadExtraLarge() async throws {
        try await Preview.render("glance-ipad", size: CGSize(width: 780, height: 400)) {
            page {
                widget(715, 330) { SHGlanceColumns(Self.fleet, stale: false, now: Self.now) }
            }
        }
    }
}
