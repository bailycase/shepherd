import Foundation
import Testing
@testable import ShepherdRemote

@Suite("iOS diagnostics budget")
struct DiagnosticsBudgetTests {
    @Test("Each kind stops at its daily limit, survives a relaunch, and renews the next UTC day")
    func dailyLimit() throws {
        let suite = "DiagnosticsBudgetTests.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let today = Date(timeIntervalSince1970: 86_400 * 20_000 + 3_600)

        let budget = DiagnosticsBudget(store: store)
        for _ in 0..<DiagnosticsBudget.Kind.error.limit { #expect(budget.take(.error, now: today)) }
        #expect(!budget.take(.error, now: today))
        // A relaunch reads the same spent day.
        #expect(!DiagnosticsBudget(store: store).take(.error, now: today))
        // Kinds are separate.
        #expect(budget.take(.transaction, now: today))
        #expect(budget.take(.error, now: today.addingTimeInterval(86_400)))
    }
}
