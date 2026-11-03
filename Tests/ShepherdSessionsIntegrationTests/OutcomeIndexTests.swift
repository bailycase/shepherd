import Foundation
import SQLite3
import Testing
import ShepherdTestSupport
@testable import ShepherdSessions

@Suite("Outcome task index", .integrationTimeLimit)
struct OutcomeIndexTests {
    @Test(arguments: [100, 1_000, 10_000])
    func sparseOldTaskPagesUseTheTaskIndex(count: Int) throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Only normal initialization creates the index; opening an older store is compatible.
        let store = try ProjectHistoryStore(beside: root.appendingPathComponent("state.json"))
        _ = store
        var db: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("project-history.sqlite").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        func exec(_ sql: String) throws { try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK) }
        try exec("BEGIN")
        for i in 1...count {
            let task = i <= 10 ? "old" : "unrelated"
            try exec("INSERT INTO records(scope,kind,identity,revision,payload) VALUES('owner','outcome','\(i)',1,'{\"taskID\":\"\(task)\",\"outcome\":{\"operationID\":\"op\"}}')")
        }
        try exec("COMMIT")
        func query(before: Int64, scan: Bool = false) -> String {
            "SELECT sequence FROM records \(scan ? "NOT INDEXED" : "") WHERE scope='owner' AND kind='outcome' AND json_extract(CAST(payload AS TEXT),'$.taskID')='old' AND sequence < \(before) ORDER BY sequence DESC LIMIT 4"
        }
        func rows(_ sql: String) throws -> ([Int64], Int32) {
            var statement: OpaquePointer?
            try #require(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            var result: [Int64] = []
            while sqlite3_step(statement) == SQLITE_ROW { result.append(sqlite3_column_int64(statement, 0)) }
            return (result, sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0))
        }
        var plan: OpaquePointer?
        try #require(sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN " + query(before: .max), -1, &plan, nil) == SQLITE_OK)
        defer { sqlite3_finalize(plan) }
        var details = ""
        while sqlite3_step(plan) == SQLITE_ROW { details += String(cString: sqlite3_column_text(plan, 3)) }
        #expect(details.contains("history_outcome_task"))
        let indexed = try rows(query(before: .max))
        let scanned = try rows(query(before: .max, scan: true))
        #expect(indexed.0 == [10, 9, 8, 7])
        #expect(indexed.0 == scanned.0)
        #expect(indexed.1 < 100, "VM work stays constant as unrelated history grows")
        #expect(indexed.1 < scanned.1)
        #expect(try rows(query(before: 7)).0 == [6, 5, 4, 3])
        print("outcome-index rows=\(count) indexed-steps=\(indexed.1) scan-steps=\(scanned.1)")
    }
}
