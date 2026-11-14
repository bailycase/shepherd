import Foundation
import ShepherdCore

// Where a thread sent to another Mac is, in the words of one sidebar line (FleetSubthreads): "<Mac> · <stage>". The stage comes from the dispatch
// record the sending Mac keeps; for a thread whose record this Mac can't see (the sender is another Mac), from the thread's own state.

public struct FleetSentStage: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case placing, noRoom, waitingWake, held, cloning, preparing, running, asking, failed, delivering
        /// The work is finished and its result is with the sender: the thread leaves the tree.
        case back
    }

    public var phase: Phase
    /// The Mac it is on, as a tag ("mini", "This Mac"); nil until one is chosen.
    public var host: String?
    /// What it is doing, after the Mac: "cloning payments-web", "goes when it wakes".
    public var words: String
    /// When it began running, in epoch milliseconds: the line ends with how long ("running 4m").
    public var runningSince: Double?

    /// A state's color, the sidebar's: the Mac's app turns each into its `AgentState`.
    public enum Mark: Equatable, Sendable {
        case hollow, running, attention, failed, done
    }

    /// The row's dot: hollow while it waits, blue while it works, amber while it asks you, red when it failed, green when it is delivering.
    public var dot: Mark {
        switch phase {
        case .placing, .noRoom, .waitingWake, .held: .hollow
        case .cloning, .preparing, .running: .running
        case .asking: .attention
        case .failed: .failed
        case .delivering, .back: .done
        }
    }

    /// The color of the words: quiet (nil) while it waits, blue while it works, amber when it asks you, red when it failed.
    public var tone: Mark? {
        switch phase {
        case .placing, .noRoom, .waitingWake, .held, .back: nil
        case .cloning, .preparing, .running, .delivering: .running
        case .asking: .attention
        case .failed: .failed
        }
    }

    /// "mini · cloning payments-web", "no Mac has room · next: mini". `elapsed` follows a running thread's words ("4m").
    public func line(elapsed: String? = nil) -> String {
        let said = [words, phase == .running ? elapsed : nil].compactMap { $0 }.joined(separator: " ")
        guard let host else { return said }
        return "\(host) · \(said)"
    }

    // MARK: From a record

    /// The stage of a dispatch this Mac sent. `thread` is the state of the thread that runs it, when this Mac can see it: a thread that asks
    /// reads "asking you" whatever its record says. `viewer` is this Mac's fleet id, `next` the Mac Auto picks next, `live` and `cap` the
    /// sender's sends going and the most it may have.
    public static func of(_ record: FleetDispatchRecord, thread: AgentStatus? = nil, viewer: UUID?, next: String?, live: Int, cap: Int) -> FleetSentStage {
        let host = tag(record.targetHostID, name: record.targetHostName ?? record.requestedHost.flatMap { FleetPlacement.isAuto($0) ? nil : $0 }, viewer: viewer)
        switch record.state {
        case .placing:
            return FleetSentStage(phase: .placing, words: "placing · choosing a Mac")
        case .waitingRoom:
            if let provider = record.limitProvider {
                return FleetSentStage(phase: .noRoom, words: "waiting for \(NativeTurnError.providerName(provider))'s limit")
            }
            return FleetSentStage(phase: .noRoom, words: "no Mac has room" + (next.map { " · next: \(FleetWherePicker.tagName($0))" } ?? ""))
        case .waitingWake:
            return FleetSentStage(phase: .waitingWake, host: host, words: "goes when it wakes")
        case .heldLimit:
            return FleetSentStage(phase: .held, words: "held · \(live) of \(cap) sends live")
        case .heldRestart:
            return FleetSentStage(phase: .held, words: "held since the restart")
        case .waitingTurn:
            return FleetSentStage(phase: .waitingWake, host: host, words: "moves when its turn ends")
        case .preparing:
            if let clone = record.clone { return FleetSentStage(phase: .cloning, host: host, words: "cloning \(clone.name)") }
            return FleetSentStage(phase: .preparing, host: host, words: "preparing worktree")
        case .running:
            if thread == .blocked { return FleetSentStage(phase: .asking, host: host, words: "asking you") }
            return FleetSentStage(phase: .running, host: host, words: "running", runningSince: record.updatedAt)
        case .delivering:
            return FleetSentStage(phase: .delivering, host: host, words: "delivering")
        case .done, .cancelled:
            return FleetSentStage(phase: .back, host: host, words: "back")
        case .failed:
            return FleetSentStage(phase: .failed, host: host, words: failureWords(record))
        }
    }

    /// The stage of a thread whose record isn't on this Mac, from its own state and the Mac it runs on.
    public static func of(thread status: AgentStatus, host: String) -> FleetSentStage {
        switch status {
        case .working: FleetSentStage(phase: .running, host: host, words: "running")
        case .blocked: FleetSentStage(phase: .asking, host: host, words: "asking you")
        case .idle, .done: FleetSentStage(phase: .back, host: host, words: "back")
        }
    }

    /// "This Mac" for the viewer's own, else the Mac's tag; nil while no Mac is named.
    static func tag(_ id: UUID?, name: String?, viewer: UUID?) -> String? {
        if let id, id == viewer { return "This Mac" }
        return name.map(FleetWherePicker.tagName)
    }

    /// Why a dispatch failed, in a few words: the Mac's own detail when it has a short one, else the code's.
    static func failureWords(_ record: FleetDispatchRecord) -> String {
        if let detail = record.failureDetail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty, detail != "unknown",
           !detail.contains("\n"), detail.count <= 40 {
            return detail
        }
        switch record.failure {
        case FleetDispatchCode.repoMissing: return "repository missing"
        case FleetDispatchCode.cloneFailed: return "couldn't clone"
        case FleetDispatchCode.repoAmbiguous: return "repository found twice"
        case FleetDispatchCode.commitUnreachable: return "commit not pushed"
        case FleetDispatchCode.hostNotReady: return "not ready for it"
        case FleetDispatchCode.noSuchHost: return "no Mac by that name"
        case FleetDispatchCode.peerGone: return "stopped answering"
        case FleetDispatchCode.refused: return "refused it"
        case FleetDispatchCode.snapshotTooLarge: return "changes too large"
        case FleetDispatchCode.snapshotMismatch, FleetDispatchCode.snapshotFailed: return "changes didn't arrive"
        default: return "not sent"
        }
    }
}

/// A sender's second line: "3 sent · 1 back", "1 sent · asking you".
public enum FleetSentSummary {
    /// How many it sent and how many came back; with none back yet, that one of them asks you. A thread that asks is in Needs you, so the line stays short.
    public static func line(sent: Int, back: Int, asking: Bool) -> String? {
        guard sent > 0 else { return nil }
        return ["\(sent) sent", back > 0 ? "\(back) back" : asking ? "asking you" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// More than this many sent threads fold under their sender until it is opened or one of them is on screen.
    public static let foldsAbove = 2
}
