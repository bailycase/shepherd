import Foundation
import ShepherdCore

// Browser tunnels (docs/browser.md › Remote): a thread hosted on another Mac has a Browser tab whose
// page renders in the viewing Mac's own web view. Its traffic to `localhost:<port>` is carried to
// `127.0.0.1:<port>` (or `::1`) on the thread's host over the one authenticated remote connection.
// This file is the wire and the flow-control arithmetic, shared by the host's server, the Mac app and
// the iOS client. It knows nothing of sockets or WebKit.

extension RemoteProtocol {
    /// The host carries Browser tunnels (`RemoteRequest.tunnel`, `RemoteReply.tunnel`) to its own
    /// loopback ports, answers `RemoteAgentQuery.devServers`, and runs a command in a new terminal
    /// pane (`RemoteRequest.openPane`'s `command`). A client lists it in `hello` too: the host
    /// carries tunnels only for a client that says it reads them. An older host lists nothing, and
    /// a thread it hosts has no Browser tab.
    public static let browserTunnelCapability = "browser.tunnel.v1"
}

/// The numbers a tunnel lives by, on both ends.
public enum BrowserTunnelLimits {
    /// Raw bytes in one data frame: with base64 and the frame around them, well under the 1 MiB cap
    /// (NDJSON.maxPayloadBytes), so a tunnel never makes another request on the connection wait
    /// behind a megabyte.
    public static let chunkBytes = 48 * 1024
    /// What each side may send before the other says it has taken some: the most either end ever
    /// holds for a tunnel, per direction.
    public static let window = 256 * 1024
    /// A receiver gives credit back in batches of at least this much, so a fast page costs one small
    /// frame per few data frames rather than one each.
    public static let creditBatch = 64 * 1024
    /// Concurrent tunnels one client connection may have.
    public static let perClient = 64
    /// Concurrent tunnels a host carries for all its clients.
    public static let perHost = 256
    /// A tunnel that carries no bytes and no keepalive for this long is closed by the host.
    public static let idleSeconds: TimeInterval = 5 * 60
    /// How often a viewer says a tunnel whose local socket is still open is wanted. A page's idle
    /// WebSocket (Vite's hot reload) is silent for hours, and closing it would make Vite reload the
    /// page, so the viewer, which knows the socket is open, keeps it up.
    public static let keepaliveSeconds: TimeInterval = 60
    /// How long the host tries to reach a port before it gives up.
    public static let connectSeconds: TimeInterval = 10
    /// A host stops reading its targets while this much waits in a client connection's write queue
    /// (which the server caps at 2 MiB, dropping the connection past it), and starts again below
    /// `resumeBacklogBytes`. The same for a client's write queue toward the host.
    public static let pauseBacklogBytes = 1024 * 1024
    public static let resumeBacklogBytes = 256 * 1024
}

/// Why a tunnel ended, in `BrowserTunnelFrame.close`.
public enum BrowserTunnelCode {
    /// Nothing is listening on the port on the host (or it did not answer).
    public static let refused = "refused"
    /// The host has no such agent, or the agent is not one this client may see.
    public static let noSuchAgent = "no_such_agent"
    /// The port is not 1...65535.
    public static let invalidPort = "invalid_port"
    /// The client, or the host, already carries as many tunnels as it will.
    public static let tooMany = "too_many"
    /// No bytes and no keepalive for `BrowserTunnelLimits.idleSeconds`.
    public static let idle = "idle"
    /// The host does not carry tunnels (an older one, or one that has switched them off).
    public static let unsupported = "unsupported"
    /// A frame that breaks the protocol: an id in use, too many bytes for the credit, a frame over
    /// the chunk size.
    public static let violation = "protocol"
    /// The connection to the target broke.
    public static let reset = "reset"
    /// The host did not reach the port in time.
    public static let timeout = "timeout"
    /// The viewer's connection to the host went away, or the viewer gave the tunnel up.
    public static let aborted = "aborted"
}

/// One message of a tunnel, either way on the connection. Tunnels are multiplexed by `tunnel`, a
/// number the client picks (increasing, never reused on a connection). None of them is answered
/// by id: an open is answered by `opened` or `close`, and everything after it is a stream.
///
/// Each direction of a tunnel is flow controlled apart: a sender may have sent at most
/// `BrowserTunnelLimits.window` bytes the receiver has not yet said (`credit`) it took. "Took" means
/// wrote to the socket it feeds, so a page or a dev server that stops reading holds its sender at
/// zero credit and nothing piles up on the way.
public enum BrowserTunnelFrame: Codable, Hashable, Sendable {
    /// Client → host: connect to `port` on the host's loopback, for `agentID`'s thread. The client
    /// may send `data` at once, without waiting for `opened`.
    case open(tunnel: Int, agentID: AgentID, port: Int)
    /// Host → client: the port answered.
    case opened(tunnel: Int)
    /// Either way: bytes for the other end's socket, at most `BrowserTunnelLimits.chunkBytes`.
    case data(tunnel: Int, bytes: Data)
    /// Either way: the sender took this many bytes of what it was sent, and the other may send that much more.
    case credit(tunnel: Int, bytes: Int)
    /// Either way: no more bytes will come from this end (a half close: the other end may still
    /// send). A tunnel is over when both ends have finished.
    case finish(tunnel: Int)
    /// Either way: the tunnel is over now, whatever was in flight (`BrowserTunnelCode`). Sent by the
    /// host to refuse an open or when a target breaks; by the client to give a tunnel up.
    case close(tunnel: Int, code: String?)
    /// Client → host: the tunnel is still wanted.
    case keepalive(tunnel: Int)

    public var tunnel: Int {
        switch self {
        case .open(let tunnel, _, _), .opened(let tunnel), .data(let tunnel, _), .credit(let tunnel, _),
             .finish(let tunnel), .close(let tunnel, _), .keepalive(let tunnel):
            tunnel
        }
    }

    /// Bytes a frame carries: what counts against a window.
    public var payloadBytes: Int {
        if case .data(_, let bytes) = self { return bytes.count }
        return 0
    }
}

/// What a sender may still send on one direction of a tunnel.
public struct BrowserTunnelCredit: Equatable, Sendable {
    public private(set) var available: Int

    public init(_ initial: Int = BrowserTunnelLimits.window) {
        available = initial
    }

    /// Takes up to `want` bytes of the credit (at most the chunk size): how many may go now.
    public mutating func take(_ want: Int) -> Int {
        let n = max(0, min(want, available, BrowserTunnelLimits.chunkBytes))
        available -= n
        return n
    }

    /// The other end took `bytes`. Never more than the window is outstanding, so a peer that
    /// grants more than it was sent cannot make this end send it more than the window.
    public mutating func grant(_ bytes: Int) {
        available = min(BrowserTunnelLimits.window, available + max(0, bytes))
    }
}

/// What a receiver has been sent, taken, and owes credit for, on one direction of a tunnel.
public struct BrowserTunnelReceipt: Equatable, Sendable {
    /// Received and not yet written to the socket it feeds.
    public private(set) var held = 0
    /// Written, and not yet given back as credit.
    public private(set) var owed = 0

    public init() {}

    /// `bytes` arrived. False when the sender had no credit for them (the tunnel is broken).
    public mutating func received(_ bytes: Int) -> Bool {
        guard bytes >= 0, held + owed + bytes <= BrowserTunnelLimits.window else { return false }
        held += bytes
        return true
    }

    /// `bytes` of what was held were written out: the credit to send back now, if it is time. A
    /// sender is never stuck: it has credit unless the window is full of what is held or owed, and
    /// a full window of owed bytes is always above the batch.
    public mutating func taken(_ bytes: Int) -> Int? {
        let n = min(max(0, bytes), held)
        held -= n
        owed += n
        guard owed >= BrowserTunnelLimits.creditBatch else { return nil }
        defer { owed = 0 }
        return owed
    }
}

public enum BrowserTunnelChunks {
    /// `data` in frames of at most `size` bytes, in order.
    public static func split(_ data: Data, size: Int = BrowserTunnelLimits.chunkBytes) -> [Data] {
        guard size > 0, !data.isEmpty else { return data.isEmpty ? [] : [data] }
        var chunks: [Data] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            chunks.append(data.subdata(in: offset..<end))
            offset = end
        }
        return chunks
    }
}

/// Where a page's URL points at its thread's host: the only pages a tunnel serves.
public enum BrowserTunnelTarget {
    /// The port on the host a `localhost`, `127.0.0.1` or `[::1]` URL names, else nil (any other
    /// host is on the web, and loads from the viewer as any page does). An http URL with no port is
    /// port 80, an https one 443.
    public static func port(of url: URL) -> Int? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return nil }
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
        guard loopback else { return nil }
        return url.port ?? (scheme == "https" ? 443 : 80)
    }
}
