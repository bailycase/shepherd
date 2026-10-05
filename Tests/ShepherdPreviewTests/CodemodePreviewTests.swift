import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdSessions

@Suite("Codemode activity previews", .serialized, .mainActorExclusive,
       .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR"))
@MainActor
struct CodemodePreviewTests {
    @Test(arguments: ["complete", "stopped", "empty", "long", "older"])
    func nestedActivities(_ state: String) async throws {
        var message = try CodemodeFixture.message()
        switch state {
        case "stopped":
            message.nestedCalls?.calls[0].status = "unfinished"
            message.nestedCalls?.complete = false
            message.details = nil
        case "empty":
            message.details = .object(["calls": .array([.object(["id": .string("script/1"), "output": .string("")])])])
        case "long":
            message.nestedCalls?.calls[0].arguments = .object(["path": .string(String(repeating: "long-directory/", count: 12) + "example.txt")])
            message.details = .object(["calls": .array([.object([
                "id": .string("script/1"), "output": .string(String(repeating: "A long output line containing a nested tool result.\n", count: 90)),
                "outputTruncated": .bool(true)])])])
        case "older": message.details = nil
        default: break
        }
        let rows = RPCThreadState.projectHistory([message])
        let bursts = nativeActivityBursts(rows.map(NativeActivityCall.init))
        let expanded = Set(rows.compactMap(\.toolCallID))
        try await Preview.renderMatrix("codemode-\(state)", size: CGSize(width: 760, height: 720)) {
            VStack(alignment: .leading, spacing: AppLayout.activitySpacing) {
                ForEach(bursts) { burst in
                    ActivityLineView(burst: burst, expanded: true, expandedCalls: expanded)
                }
                Spacer(minLength: 0)
            }
            .padding(NW.Space.xl)
            .frame(width: 760, height: 720, alignment: .topLeading)
            .background(Color.nw.bgWindow)
        }
    }
}
