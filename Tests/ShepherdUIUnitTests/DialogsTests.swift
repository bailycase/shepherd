import Testing
@testable import ShepherdUI

@Suite("Dialogs")
struct DialogsTests {
    @Test(arguments: [
        (nil, nil),
        ("", nil),
        (" \n\n ", nil),
        ("2 files", "2 files"),
        ("fatal: 'origin' does not appear to be a git repository\nfatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists.\n",
         "fatal: 'origin' does not appear to be a git repository fatal: Could not read from remote repository. Please make sure you have the correct access rights and the repository exists."),
    ] as [(String?, String?)])
    func checklistDetailsReadOnOneLine(detail: String?, shown: String?) {
        #expect(NWChecklistMetrics.oneLine(detail) == shown)
    }
}
