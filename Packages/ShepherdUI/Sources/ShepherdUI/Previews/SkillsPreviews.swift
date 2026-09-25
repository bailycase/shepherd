import SwiftUI

#Preview("Skill parts") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            HStack(spacing: NW.Space.m) {
                NWUpdatePill()
                NWOfficialSeal()
                NWTag("/skill only", mono: true)
            }
            HStack(spacing: NW.Space.s) {
                NWFileChip("SKILL.md")
                NWFileChip("reference.md")
                NWFileChip("scripts/", count: 8, kind: .code)
                NWFileChip("references/", count: 2, kind: .folder)
            }
            VStack(alignment: .leading, spacing: 0) {
                NWHostStateRow("This Mac", detail: "installed · ready in new threads", mark: .done)
                NWHostStateRow("build-01", detail: "copying files", mark: .working)
                NWHostStateRow("horizon", detail: "offline · installs when it's back", mark: .offline)
            }
            NWBudgetBar([true, true, true, true, true, true, false]).frame(width: 240)
            VStack(alignment: .leading, spacing: NW.Space.m) {
                NWRadioOption("Automatically", note: "The agent reads it when a task calls for it.", selected: true) {}
                NWRadioOption("Only when I type /skill:pdf", note: "Stays out of the agent's prompt until you call it.", selected: false) {}
            }
            .frame(width: 300, alignment: .leading)
        }
    }
}
