import Foundation
import ShepherdCore
import ShepherdProtocol

/// What a client offers on one of a host's missions, from its record (and the Spec Kit reads and
/// review the client last made): the same rules the Mac's Missions page draws its controls by.
/// The host checks each again; this only decides what is shown.
public struct RemoteMissionControls: Equatable, Sendable {
    public enum Primary: Equatable, Sendable {
        case launch, resume, resumePlanning
        /// A finished completion report (/speckit.converge) only the owner can accept.
        case accept(attemptID: UUID, lane: String)
    }

    /// A planner question waiting on the owner, the message it is in, and its suggested answers.
    public struct Question: Equatable, Sendable {
        public var text: String
        public var choices: [String]
        public var replyTo: UUID?
        public init(text: String, choices: [String], replyTo: UUID?) { self.text = text; self.choices = choices; self.replyTo = replyTo }
    }

    /// A repository whose stock Spec Kit files need the owner's OK, bound to the files as last read.
    public struct Consent: Equatable, Sendable, Identifiable {
        public var spaceID: SpaceID
        public var name: String
        public var fingerprint: String
        /// It was allowed before and its files changed since.
        public var changed: Bool
        /// Every other repository is allowed, so this grant lets planning continue.
        public var last: Bool
        public var id: SpaceID { spaceID }
    }

    /// A repository with no stock Spec Kit project (or none for pi): the owner may set it up.
    public struct SetUp: Equatable, Sendable, Identifiable {
        public var spaceID: SpaceID
        public var name: String
        public var id: SpaceID { spaceID }
    }

    public var primary: Primary?
    public var pause: Bool
    /// "Stop planning", "Stop mission", "Stop publishing"; nil when nothing runs.
    public var stop: String?
    public var question: Question?
    /// The owner may talk to the planner (an answer, or feedback on the map).
    public var message: Bool
    public var consents: [Consent]
    public var setUps: [SetUp]
    /// The mission has a review to read (validated, or published).
    public var review: Bool
    public var changes: Bool
    public var revalidate: Bool
    public var runAgain: Bool

    public init(_ mission: Mission, reports: [SpaceID: SpecKitPreflight] = [:]) {
        let run = mission.run, phase = run?.phase ?? .map
        let published = run?.publicationApproval != nil
        let idle = [.map, .paused, .stopped].contains(phase)
        let stations = mission.draft.plan?.stations ?? []
        let stationAttempts = run?.attempts.filter { $0.stationID != nil } ?? []
        let blocked = run?.pendingQuestion != nil
        let specKit = run?.specKit
        let consented = specKit.map { !$0.lanes.isEmpty && $0.lanes.allSatisfy { $0.consentFingerprint != nil } } ?? false
        let finished: (SpecKitCommand) -> Bool = { command in
            guard let lanes = specKit?.lanes, !lanes.isEmpty, let run else { return false }
            return lanes.allSatisfy { lane in
                let station = SpecKit.stationID(mission.id, lane.spaceID, command.rawValue)
                return run.attempts.contains { $0.stationID == station && $0.command == command && $0.status == .succeeded }
            }
        }
        let specKitNext = specKit == nil ? nil : [SpecKitCommand.specify, .plan, .tasks].first { !finished($0) }
        func name(_ space: SpaceID) -> String { mission.draft.plan?.lanes.first { $0.spaceID == space }?.name ?? "repository" }

        var accept: Primary?
        for lane in specKit?.lanes ?? [] {
            guard let convergence = lane.convergence, !convergence.accepted, convergence.outcome != .tasksAppended,
                  convergence.outcome != .missing, run?.attempts.first(where: { $0.id == convergence.attemptID })?.status == .succeeded else { continue }
            accept = .accept(attemptID: convergence.attemptID, lane: name(lane.spaceID)); break
        }

        pause = (phase == .planning || phase == .running) && !published
        stop = switch phase {
        case .planning: "Stop planning"
        case .running, .paused: "Stop mission"
        case .publishing: "Stop publishing"
        default: nil
        }
        primary = nil
        if idle {
            let needsPlan = stations.isEmpty || (phase != .map && mission.approvedPlanRevision == nil && stationAttempts.isEmpty)
            let specKitBlocked = specKit != nil && (!consented || specKitNext != nil)
            if !published, !blocked, let accept { primary = accept }
            else if !published && !blocked && !specKitBlocked && !(phase == .map && needsPlan) {
                primary = needsPlan ? .resumePlanning : phase == .map ? .launch : .resume
            } else if !published && !blocked && specKit != nil && consented && specKitNext != nil {
                primary = .resumePlanning
            }
        }
        question = run?.pendingQuestion.map { text in
            Question(text: text, choices: run?.pendingChoices ?? [],
                     replyTo: run?.messages.last { $0.role == .assistant && $0.question != nil }?.id)
        }
        message = idle && !published && run != nil
        var consents: [Consent] = [], setUps: [SetUp] = []
        if idle, !published, let lanes = specKit?.lanes {
            let allowed = Set(lanes.filter { lane in
                guard let report = reports[lane.spaceID] else { return lane.consentFingerprint != nil }
                return report.status == .ready && lane.consentFingerprint == report.consentFingerprint
            }.map(\.spaceID))
            for lane in lanes {
                guard let report = reports[lane.spaceID] else { continue }
                if report.status == .ready, lane.consentFingerprint != report.consentFingerprint {
                    consents.append(Consent(spaceID: lane.spaceID, name: name(lane.spaceID), fingerprint: report.consentFingerprint,
                                            changed: lane.consentFingerprint != nil,
                                            last: allowed.union([lane.spaceID]).count == lanes.count))
                } else if [.notInitialized, .piIntegrationMissing].contains(report.status) {
                    setUps.append(SetUp(spaceID: lane.spaceID, name: name(lane.spaceID)))
                }
            }
        }
        self.consents = consents
        self.setUps = setUps
        review = phase == .review || phase == .publishing || ([.paused, .stopped, .done].contains(phase) && run?.reviewFingerprint != nil)
        changes = phase == .review && !published
        // The review's Re-run all checks: every check and the validator again on the current worktrees.
        revalidate = changes
        runAgain = phase == .done || phase == .stopped
    }

    /// The fingerprint a Publish approves: the run's `reviewFingerprint`, only while `reviews` (the
    /// repositories as last read) match every worktree receipt the validation saw. Nil: nothing to publish.
    public static func publishable(_ mission: Mission, reviews: [RemoteMissionReview]) -> String? {
        guard let run = mission.run, let fingerprint = run.reviewFingerprint, !fingerprint.isEmpty else { return nil }
        let authorized = run.publicationApproval != nil
        guard [.review, .paused].contains(run.phase) || (run.phase == .stopped && authorized) else { return nil }
        let stale = run.checkouts.isEmpty || run.checkouts.count != reviews.count || run.checkouts.contains { checkout in
            !reviews.contains { repo in
                repo.spaceID == checkout.spaceID && repo.fingerprint == checkout.fingerprint
                    && (repo.head == checkout.head || (authorized && (checkout.publishedHead.map { repo.head.hasPrefix($0) } ?? true)))
            }
        }
        return stale ? nil : fingerprint
    }
}
