import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// A viewer's claim on one remote thread's browser (docs/browser.md › Remote): when it claims and
/// when it lets go, from what the tab and the connection do, with the clock handed in.
@Suite("Browser drive claimant")
struct BrowserDriveClaimantTests {
    private let t0 = Date(timeIntervalSince1970: 5_000)

    /// A claimant whose connection is up and whose claim the host has answered.
    private func owning(grace: TimeInterval = 30) -> BrowserDriveClaimant {
        var claimant = BrowserDriveClaimant(grace: grace)
        _ = claimant.connection(up: true)
        _ = claimant.tabShown()
        claimant.claimed()
        return claimant
    }

    @Test func aTabShownOnALiveConnectionClaimsTheAgentsBrowser() {
        var claimant = BrowserDriveClaimant()
        let r1 = claimant.connection(up: true)
        #expect(r1 == nil, "nothing is claimed for a tab nobody looks at")
        let r2 = claimant.tabShown()
        #expect(r2 == .claim)
        #expect(claimant.phase == .claiming && claimant.holds)
        let r3 = claimant.claimed()
        #expect(r3)
        #expect(claimant.phase == .owned)
        let r4 = claimant.tabShown()
        #expect(r4 == nil, "showing it again claims nothing new")
    }

    @Test func aTabShownBeforeTheConnectionIsUpClaimsWhenItComes() {
        var claimant = BrowserDriveClaimant()
        let r5 = claimant.tabShown()
        #expect(r5 == nil && claimant.phase == .idle)
        let r6 = claimant.connection(up: true)
        #expect(r6 == .claim)
        let r7 = claimant.connection(up: true)
        #expect(r7 == nil, "and only once")
    }

    @Test func aTabThatGoesOutOfSightKeepsItsClaimForAWhileThenLetsGo() {
        var claimant = owning(grace: 30)
        claimant.tabHidden(now: t0)
        #expect(claimant.releaseDeadline == t0.addingTimeInterval(30))
        let r8 = claimant.release(now: t0.addingTimeInterval(29))
        #expect(r8 == nil, "a quick look at another tab keeps the agent's page")
        #expect(claimant.phase == .owned)
        let r9 = claimant.release(now: t0.addingTimeInterval(30))
        #expect(r9 == .release)
        #expect(claimant.phase == .idle && claimant.releaseDeadline == nil && !claimant.holds)
        let r10 = claimant.release(now: t0.addingTimeInterval(99))
        #expect(r10 == nil, "it is let go once")
    }

    @Test func aTabThatComesBackInTimeKeepsTheClaimAndClaimsNothingNew() {
        var claimant = owning()
        claimant.tabHidden(now: t0)
        let r11 = claimant.tabShown()
        #expect(r11 == nil)
        #expect(claimant.releaseDeadline == nil, "the grace is over once it is shown")
        let r12 = claimant.release(now: t0.addingTimeInterval(500))
        #expect(r12 == nil)
        #expect(claimant.phase == .owned)
    }

    @Test func aTabThatComesBackAfterTheGraceClaimsAgain() {
        var claimant = owning()
        claimant.tabHidden(now: t0)
        let r13 = claimant.release(now: t0.addingTimeInterval(31))
        #expect(r13 == .release)
        let r14 = claimant.tabShown()
        #expect(r14 == .claim)
    }

    @Test func hidingATabThatWasNeverShownHasNoDeadline() {
        var claimant = BrowserDriveClaimant()
        _ = claimant.connection(up: true)
        claimant.tabHidden(now: t0)
        #expect(claimant.releaseDeadline == nil)
        var claiming = BrowserDriveClaimant()
        _ = claiming.connection(up: true)
        _ = claiming.tabShown()
        claiming.tabHidden(now: t0)
        #expect(claiming.releaseDeadline != nil, "a claim on its way is let go too")
        let r15 = claiming.release(now: t0.addingTimeInterval(31))
        #expect(r15 == .release, "and its answer, when it comes, is not held")
        let r16 = claiming.claimed()
        #expect(!r16)
    }

    @Test func aDroppedConnectionTakesTheClaimAndAShownTabClaimsAgainOnTheNext() {
        var claimant = owning()
        let r17 = claimant.connection(up: false)
        #expect(r17 == nil)
        #expect(claimant.phase == .idle && !claimant.holds)
        let r18 = claimant.connection(up: true)
        #expect(r18 == .claim)
        #expect(claimant.phase == .claiming)
    }

    @Test func aDroppedConnectionWithTheTabOutOfSightClaimsNothingOnTheNext() {
        var claimant = owning()
        claimant.tabHidden(now: t0)
        _ = claimant.connection(up: false)
        let r19 = claimant.connection(up: true)
        #expect(r19 == nil)
        #expect(claimant.releaseDeadline == nil)
    }

    // MARK: Another viewer takes it

    @Test func aViewerThatIsSupersededStaysSupersededUntilItsTabIsShownAgain() {
        var claimant = owning()
        claimant.ended(reason: BrowserDriveEnd.superseded)
        #expect(claimant.phase == .superseded && !claimant.holds)
        let r20 = claimant.tabShown()
        #expect(r20 == nil, "a tab that never went away does not take it back")
        let r21 = claimant.connection(up: true)
        #expect(r21 == nil, "nor does the connection's word")
        claimant.tabHidden(now: t0)
        let r22 = claimant.tabShown()
        #expect(r22 == .claim, "showing it again does")
        #expect(claimant.phase == .claiming)
    }

    @Test func aClaimThatLosesTheRaceIsSuperseded() {
        var claimant = BrowserDriveClaimant()
        _ = claimant.connection(up: true)
        _ = claimant.tabShown()
        claimant.claimFailed(code: BrowserDriveEnd.superseded)
        #expect(claimant.phase == .superseded)
    }

    @Test func aRefusedClaimIsTriedAgainWhenTheTabIsShownOrTheConnectionComesBack() {
        var claimant = BrowserDriveClaimant()
        _ = claimant.connection(up: true)
        _ = claimant.tabShown()
        claimant.claimFailed(code: "no_such_agent")
        #expect(claimant.phase == .refused(code: "no_such_agent"))
        claimant.tabHidden(now: t0)
        let r23 = claimant.tabShown()
        #expect(r23 == .claim)
        claimant.claimFailed(code: "too_many")
        let r24 = claimant.connection(up: true)
        #expect(r24 == .claim, "a new connection tries again")
    }

    @Test func aHostThatTookItBackForSilenceIsNotClaimedAgainUntilTheTabIsShownAgain() {
        var claimant = owning()
        claimant.ended(reason: BrowserDriveEnd.unresponsive)
        #expect(claimant.phase == .idle)
        claimant.tabHidden(now: t0)
        let r25 = claimant.tabShown()
        #expect(r25 == .claim)
        claimant.ended(reason: BrowserDriveEnd.agentGone)
        #expect(claimant.phase == .idle)
    }

    @Test func anAnswerOnlyCountsWhileAClaimIsWaitingForIt() {
        var idle = BrowserDriveClaimant()
        let r26 = idle.claimed()
        #expect(!r26)
        idle.claimFailed(code: "x")
        #expect(idle.phase == .idle, "a failure nobody waited for changes nothing")
        var owner = owning()
        let r27 = owner.claimed()
        #expect(!r27)
        owner.claimFailed(code: "late")
        #expect(owner.phase == .owned, "a late failure does not take an owned claim")
    }

    @Test func theGraceIsTheDocumentedThirtySeconds() {
        #expect(BrowserDriveLimits.hiddenGraceSeconds == 30)
        #expect(BrowserDriveClaimant().grace == 30)
    }
}
