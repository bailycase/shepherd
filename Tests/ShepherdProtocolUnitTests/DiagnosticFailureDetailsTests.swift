import Testing
import ShepherdProtocol

@Suite("Diagnostic failure labels")
struct DiagnosticFailureDetailsTests {
    @Test func toolKindsAreBoundedAndNeverRetainCustomNames() {
        for kind: DiagnosticFailureDetails.ToolKind in [.read, .bash, .write, .edit, .other] {
            #expect(DiagnosticFailureDetails.ToolKind(name: kind.rawValue) == kind)
        }
        #expect(DiagnosticFailureDetails.ToolKind(name: "mcp__PRIVATE_SERVER__PRIVATE_TOOL") == .mcp)
        #expect(DiagnosticFailureDetails.ToolKind(name: "/PRIVATE_PATH?token=PRIVATE_SECRET") == .other)
    }

    @Test func startupLabelsUseOnlyTheExistingProblemKind() {
        let stages: [NativeStartProblem.Kind: DiagnosticFailureDetails.StartupStage] = [
            .notSignedIn: .initialization, .extensionFailed: .initialization,
            .engineMissing: .launch, .homeUnsafe: .preflight, .folderMissing: .preflight,
            .resumedAsNew: .resume, .exited: .unknown
        ]
        for kind in NativeStartProblem.Kind.allCases {
            let details = DiagnosticFailureDetails(startupKind: kind)
            #expect(details.startupStage == stages[kind])
            #expect(details.attributes["startup.kind"] == kind.rawValue)
            #expect(DiagnosticFailureDetails.sanitized(details.attributes) == details.attributes)
        }
    }

    @Test func sanitizationRejectsUnknownKeysAndValues() {
        let privateValue = "/PRIVATE_PATH?token=PRIVATE_SECRET"
        let poisoned = Dictionary(uniqueKeysWithValues: ["failure.category", "tool.kind", "startup.kind", "startup.stage", privateValue].map { ($0, privateValue) })
        #expect(DiagnosticFailureDetails.sanitized(poisoned).isEmpty)
        for category in DiagnosticFailureDetails.Category.allCases {
            let details = DiagnosticFailureDetails(category: category, toolKind: .mcp)
            #expect(DiagnosticFailureDetails.sanitized(details.attributes) == details.attributes)
        }
    }
}
