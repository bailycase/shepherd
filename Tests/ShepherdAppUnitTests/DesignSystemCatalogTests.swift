import Foundation
import ShepherdCore
import ShepherdProtocol
import Testing
@testable import ShepherdApp

/// The app's read of its design systems: a load asked for while one runs must read what changed since.
@Suite("Design system catalog")
@MainActor
struct DesignSystemCatalogTests {
    /// The server's one system, at a revision the test moves. Main-actor state, read from the reader's
    /// closures on the main actor as the catalog calls them.
    @MainActor final class Server {
        var revision: UInt64 = 1
        var value = "#4f46e5"
        var summary: DesignSystemSummary {
            DesignSystemSummary(info: DesignSystemInfo(namespace: "acme-web", title: "acme-web", revision: revision, createdAt: 0))
        }
        var read: DesignSystemRead {
            DesignSystemRead(summary: summary, tokens: DesignSystemTokens(name: "acme-web", colors: [.init(name: "--accent", value: value)]),
                             readme: nil, files: [])
        }
    }

    /// A load runs to its end; then, before the task that ran it is gone, Re-sync changes the system
    /// and asks for a load. That load must read the new revision, not wait on the finished task and
    /// keep what it read before the re-sync (the page then showed the old value until the next load).
    @Test func aLoadAskedForAsTheLastOneEndsReadsWhatChangedSince() async {
        let server = Server()
        let (finished, finishing) = AsyncStream<Void>.makeStream()
        let reader = DesignSystemReader(
            summaries: { await MainActor.run { [server.summary] } },
            system: { _ in
                // The first load's last read: say so, so the test can land a re-sync right after it.
                let read = await MainActor.run { server.read }
                finishing.yield()
                return read
            },
            resync: { _ in DesignSystemSyncResult(summary: await MainActor.run { server.summary }, changes: DesignSystemSyncChanges()) })
        let catalog = DesignSystemCatalog()
        let first = Task { await catalog.load(reader) }
        var reads = finished.makeAsyncIterator()
        await reads.next()
        // The first load has read revision 1 and is about to finish. The system moves, and a load is asked for.
        server.revision = 2
        server.value = "#e11d48"
        await catalog.load(reader)
        await first.value
        #expect(catalog.tokens("acme-web")?.colors.first?.value == "#e11d48")
        #expect(catalog.summary("acme-web")?.info.revision == 2)
        finishing.finish()
    }
}
