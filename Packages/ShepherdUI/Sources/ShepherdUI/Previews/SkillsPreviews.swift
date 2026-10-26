import SwiftUI

#Preview("Skill parts") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            HStack(spacing: SH.Space.m) {
                SHUpdatePill()
                SHOfficialSeal()
                SHTag("/skill only", mono: true)
            }
            HStack(spacing: SH.Space.s) {
                SHSkillFileChip("SKILL.md")
                SHSkillFileChip("reference.md")
                SHSkillFileChip("scripts/", count: 8, kind: .code)
                SHSkillFileChip("references/", count: 2, kind: .folder)
            }
            VStack(alignment: .leading, spacing: 0) {
                SHHostStateRow("This Mac", detail: "installed · ready in new threads", mark: .done)
                SHHostStateRow("build-01", detail: "copying files", mark: .working)
                SHHostStateRow("horizon", detail: "offline · installs when it's back", mark: .offline)
            }
            SHBudgetBar([true, true, true, true, true, true, false]).frame(width: 240)
            VStack(alignment: .leading, spacing: SH.Space.m) {
                SHRadioOption("Automatically", note: "The agent reads it when a task calls for it.", selected: true) {}
                SHRadioOption("Only when I type /skill:pdf", note: "Stays out of the agent's prompt until you call it.", selected: false) {}
            }
            .frame(width: 300, alignment: .leading)
        }
    }
}
