import Foundation
import Testing
@testable import ShepherdProtocol

/// `DiffFile` is the review's wire payload: a host encodes the files it loaded from git, and any
/// client (the Mac, iOS) decodes them from `RemoteAgentResult.review(files:)`.
@Suite("Diff files")
struct DiffFileTests {
    static let unified = """
    diff --git a/App/iOS/FleetView.swift b/App/iOS/FleetView.swift
    --- a/App/iOS/FleetView.swift
    +++ b/App/iOS/FleetView.swift
    @@ -12,3 +12,3 @@ struct FleetView: View {
     let connected = true
    -Section {
    +HostCard(connection: connection)
     List {
    diff --git a/Tests/NewTests.swift b/Tests/NewTests.swift
    new file mode 100644
    --- /dev/null
    +++ b/Tests/NewTests.swift
    @@ -0,0 +1,2 @@
    +import Testing
    +@Test func works() {}
    """

    @Test func parsingKeepsPathsStatusAndLineNumbers() throws {
        let files = DiffFile.parse(Self.unified)
        #expect(files.map(\.displayPath) == ["App/iOS/FleetView.swift", "Tests/NewTests.swift"])
        let fleet = try #require(files.first)
        #expect((fleet.addedCount, fleet.removedCount) == (1, 1))
        #expect(!fleet.isNew && !fleet.isDeleted && !fleet.isRenamed)
        let lines = try #require(fleet.hunks.first).lines
        #expect(lines.map(\.kind) == [.context, .removed, .added, .context])
        #expect(lines.map(\.oldLine) == [12, 13, nil, 14])
        #expect(lines.map(\.newLine) == [12, nil, 13, 14])
        #expect(files[1].isNew && files[1].addedCount == 2)
    }

    @Test func filesSurviveTheReviewReplyUnchanged() throws {
        let files = DiffFile.parse(Self.unified)
        let reply = RemoteAgentResult.review(files: try JSONEncoder().encode(files), reference: "origin/main...HEAD")
        guard case .review(let data, let reference) = try Wire.roundTrip(reply) else {
            Issue.record("not a review reply")
            return
        }
        #expect(reference == "origin/main...HEAD")
        #expect(try JSONDecoder().decode([DiffFile].self, from: data) == files)
    }

    /// The keys a host from before the move writes: a client decodes them as they were.
    @Test func decodesTheHostsExistingEncoding() throws {
        let json = """
        [{"oldPath":"a.txt","newPath":"a.txt","displayPath":"a.txt","isNew":false,"isDeleted":false,"isRenamed":false,
          "isBinary":false,"addedCount":1,"removedCount":0,
          "hunks":[{"header":"@@ -1 +1,2 @@","lines":[{"kind":{"context":{}},"text":"a","oldLine":1,"newLine":1,"id":0},
                                                  {"kind":{"added":{}},"text":"b","newLine":2,"id":1}]}]}]
        """
        let file = try #require(try JSONDecoder().decode([DiffFile].self, from: Data(json.utf8)).first)
        #expect(file.displayPath == "a.txt")
        #expect(file.hunks.first?.lines.map(\.kind) == [.context, .added])
        #expect(file.addedCount == 1)
    }
}
