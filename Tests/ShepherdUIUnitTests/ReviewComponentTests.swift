import Foundation
import Testing
@testable import ShepherdUI

/// The Review board's copy and mappings: fold labels, signs, status letters, and what VoiceOver
/// reads for a line or a file chip.
@Suite("Review components")
struct ReviewComponentTests {
    @Test(arguments: [
        (13, NWDiffLineKind.removed, "18–32", "+ 13 more removed lines · 18–32"),
        (1, .added, "7–7", "+ 1 more added line · 7–7"),
        (6, .context, "", "+ 6 more unchanged lines"),
    ])
    func foldRowsCountTheirLinesAndRange(count: Int, kind: NWDiffLineKind, range: String, label: String) {
        #expect(NWFoldRow.label(count: count, kind: kind, range: range) == label)
    }

    @Test(arguments: [(NWDiffLineKind.context, ""), (.added, "+"), (.removed, "\u{2212}")])
    func signsUseATrueMinus(kind: NWDiffLineKind, sign: String) {
        #expect(kind.sign == sign)
    }

    @Test func everyStatusHasItsOwnLetter() {
        #expect(NWFileStatus.allCases.map(\.letter) == ["M", "A", "D", "R"])
    }

    @Test(arguments: [
        (NWDiffLineKind.removed, 16 as Int?, nil as Int?, "  if let x {", "Removed line 16: if let x {"),
        (.added, nil, 15, "Section {", "Added line 15: Section {"),
        (.context, 12, 12, "   ", "Line 12, blank"),
    ])
    func linesReadAsOneElement(kind: NWDiffLineKind, old: Int?, new: Int?, source: String, text: String) {
        let line = NWDiffLineContent(id: "l", key: 0, kind: kind, oldNumber: old, newNumber: new, text: AttributedString(source), source: source)
        #expect(line.accessibilityText == text)
    }

    @Test func aLineIsCitedByItsNewNumberThenItsOld() {
        let line = { (old: Int?, new: Int?) in
            NWDiffLineContent(id: "l", key: 0, kind: .context, oldNumber: old, newNumber: new, text: "", source: "").number
        }
        #expect(line(3, 5) == 5 && line(3, nil) == 3 && line(nil, nil) == nil)
    }

    @Test(arguments: [("App/iOS/FleetView.swift", "App/iOS/", "FleetView.swift"), ("README.md", "", "README.md")])
    func pathsSplitIntoDirectoryAndName(path: String, directory: String, name: String) {
        let split = NWFileHeader.split(path)
        #expect(split.directory == directory && split.name == name)
    }

    @Test(arguments: [(NWFileStatus.modified, true), (.renamed, true), (.added, false), (.deleted, false)])
    func onlyChangedFilesShowTheirStatInTheStrip(status: NWFileStatus, shows: Bool) {
        #expect(NWFileStrip.Item(id: "a", path: "a", status: status, added: 1, removed: 1).showsStat == shows)
    }

    @Test func aChipReadsItsNameStatusAndCounts() {
        let item = NWFileStrip.Item(id: "a", path: "App/FleetView.swift", status: .modified, added: 10, removed: 54, isViewed: true, isTouched: true)
        #expect(item.accessibilityText == "FleetView.swift, modified, 10 added, 54 removed, viewed, being edited")
    }

    @Test func rowIdentityComesFromEachKind() {
        let line = NWDiffLineContent(id: "line", key: 1, kind: .added, oldNumber: nil, newNumber: 1, text: "", source: "")
        let rows: [NWDiffRow] = [.hunk(id: "hunk", header: "@@"), .line(line), .fold(id: "fold", count: 2, kind: .context, range: "")]
        #expect(rows.map(\.id) == ["hunk", "line", "fold"])
    }
}
