import Foundation
import ShepherdCore

// What a thread that has not started on its Mac yet says on its sidebar row, as any thread's second line does: "starting on mini", "waiting for
// mini to wake", "cloning payments-web on mini", or why it failed. The row is a normal thread's: the Mac is its tag, never part of the words.
// The stage comes from the record the sending Mac keeps.

public struct FleetSentStage: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case placing, noRoom, waitingWake, held, cloning, preparing, running, failed
        /// The work is finished.
        case back
    }

    public var phase: Phase
    /// The Mac it is on, as a tag ("mini", "This Mac"); nil until one is chosen.
    public var host: String?
    /// What it is doing: "starting on mini", "waiting for mini to wake".
    public var words: String

    /// A state's color, the sidebar's: the Mac's app turns each into its `AgentState`.
    public enum Mark: Equatable, Sendable {
        case hollow, running, failed, done
    }

    /// The row's dot: hollow while it waits, blue while it starts, red when it failed.
    public var dot: Mark {
        switch phase {
        case .placing, .noRoom, .waitingWake, .held: .hollow
        case .cloning, .preparing, .running: .running
        case .failed: .failed
        case .back: .done
        }
    }

    /// The color of the words: quiet (nil) while it waits, blue while it starts, red when it failed.
    public var tone: Mark? {
        switch phase {
        case .placing, .noRoom, .waitingWake, .held, .back: nil
        case .cloning, .preparing, .running: .running
        case .failed: .failed
        }
    }

    /// The row's Mac tag: the Mac's name, nothing for This Mac, for one that has left, or before one is chosen.
    public var tag: String? {
        guard let host, host != "This Mac", host != FleetDispatchPresentation.macLeft else { return nil }
        return host
    }

    // MARK: From a record

    /// The stage of a dispatch this Mac sent. `viewer` is this Mac's fleet id; `macs` names the Macs of the fleet by id
    /// (`FleetSnapshot.macNames`): a thread sent from New thread names its Mac by id until one is chosen.
    public static func of(_ record: FleetDispatchRecord, viewer: UUID?, macs: [UUID: String] = [:]) -> FleetSentStage {
        let host = tag(FleetDispatchPresentation.hostID(of: record), name: FleetDispatchPresentation.hostName(of: record, macs: macs), viewer: viewer)
        /// " on mini": where it happens, for a Mac other than this one.
        let on = host.flatMap { $0 == "This Mac" ? nil : " on \($0)" } ?? ""
        switch record.state {
        case .placing:
            return FleetSentStage(phase: .placing, words: "starting")
        case .waitingRoom:
            if let provider = record.limitProvider {
                return FleetSentStage(phase: .noRoom, words: "waiting for \(NativeTurnError.providerName(provider))'s limit")
            }
            return FleetSentStage(phase: .noRoom, words: "waiting for a Mac with room")
        case .waitingWake:
            return FleetSentStage(phase: .waitingWake, host: host, words: "waiting for \(host ?? "its Mac") to wake")
        case .heldLimit:
            return FleetSentStage(phase: .held, words: "waiting for another thread to finish")
        case .heldRestart:
            return FleetSentStage(phase: .held, words: "paused by the restart")
        case .waitingTurn:
            return FleetSentStage(phase: .waitingWake, host: host, words: "moving when its turn ends")
        case .preparing:
            if let clone = record.clone { return FleetSentStage(phase: .cloning, host: host, words: "cloning \(clone.name)\(on)") }
            return FleetSentStage(phase: .preparing, host: host, words: "starting\(on)")
        case .running, .delivering:
            return FleetSentStage(phase: .running, host: host, words: "working")
        case .done, .cancelled:
            return FleetSentStage(phase: .back, host: host, words: "done")
        case .failed:
            let why = failureWords(record)
            return FleetSentStage(phase: .failed, host: host, words: host == FleetDispatchPresentation.macLeft ? "\(host!) · \(why)" : why)
        }
    }

    /// "This Mac" for the viewer's own, else the Mac's tag; nil while no Mac is named.
    static func tag(_ id: UUID?, name: String?, viewer: UUID?) -> String? {
        if let id, id == viewer { return "This Mac" }
        return name.map(FleetWherePicker.tagName)
    }

    /// Why a dispatch failed, in a few words: what the Mac lacked when it was not ready, else its own short detail, else the code's.
    static func failureWords(_ record: FleetDispatchRecord) -> String {
        let detail = record.failureDetail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let short = detail.isEmpty || detail.contains("\n") || detail.count > 40 ? nil : detail
        if record.failure == FleetDispatchCode.hostNotReady, let short {
            // The placement's words (`FleetPlacement.named`): a tool it lacks, "unknown" before it has reported, "unreachable" when it didn't answer.
            switch short {
            case "unknown": return "hasn't reported yet"
            case "unreachable": return "isn't answering"
            case _ where short.hasSuffix(" models"): return "can't run \(short)"
            case _ where !short.contains(" "): return "\(short) isn't installed"
            default: break
            }
        }
        if let short, short != "unknown" { return short }
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
        default: return "didn't start"
        }
    }
}
