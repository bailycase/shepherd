import SwiftUI

// Deleting and importing designs (DesignLifecycleStates), light and dark.

#Preview("Delete design dialog") {
    SHPreviewBoth {
        SHDesignAlert(symbol: "trash", title: "Delete “Checkout funnel dashboard”?") {
            SHDesignAlertList {
                SHDesignAlertLine(symbol: "trash", role: .goes,
                                  Text("\(SHDesignAlertMessage.strong("4 boards")), their 23 versions and 2 comments"))
                SHDesignAlertLine(symbol: "text.bubble", role: .goes, Text("The design agent’s chat for this design"))
                SHDesignAlertLine(symbol: "checkmark", role: .stays,
                                  Text("Stays: \(SHDesignAlertMessage.mono("acme-web")), the design system it uses"))
            }
            Text("You can undo right after.")
                .font(.shSans(SHDesignMetrics.alertMessageSize))
                .foregroundStyle(Color.sh.textTertiary)
            SHDesignAlertWarning("The design agent is drawing 2 boards right now. Deleting stops it, and what it’s drawing is lost.")
        } actions: {
            Button("Cancel") {}.buttonStyle(.sh(.secondary))
            Button("Stop and delete") {}.buttonStyle(.sh(.dangerFill))
        }
    }
}

#Preview("Import error dialog") {
    SHPreviewBoth {
        SHDesignAlert(symbol: "exclamationmark.triangle", title: "Couldn’t import “checkout-funnel”", width: SHDesignMetrics.alertWideWidth) {
            SHDesignAlertMessage("3 boards point to files outside the project folder. Shepherd only reads what’s inside the project, so it stopped.")
            SHDesignAlertLinks([.init(from: "boards/hero.html", to: "../shared/logo.svg"),
                                .init(from: "boards/pricing.html", to: "../../fonts/Inter.woff2"),
                                .init(from: "boards/footer.html", to: "/Users/sam/Desktop/bg.png")])
            SHDesignAlertReassurance("Nothing was imported.")
        } actions: {
            Button("OK") {}.buttonStyle(.sh(.primary))
        }
    }
}

#Preview("Undo toast") {
    SHPreviewBoth {
        VStack(spacing: SH.Space.l) {
            SHUndoToast(message: Text("Deleted \(Text("Checkout funnel dashboard").fontWeight(.semibold))."), actionTitle: "Undo",
                        actionSymbol: "arrow.uturn.backward", action: {}, dismiss: {})
            SHUndoToast(tone: .failed,
                        message: Text("Couldn’t delete \(Text("Checkout funnel dashboard").fontWeight(.semibold)). build-01, where it’s saved, didn’t answer, so it’s back."),
                        actionTitle: "Try again", actionSymbol: "arrow.clockwise", action: {}, dismiss: {})
        }
        .padding(SH.Space.l)
    }
}

#Preview("Import cards") {
    SHPreviewBoth {
        HStack(alignment: .top, spacing: SH.Space.xl) {
            SHImportingCard(title: "Checkout funnel", done: 7, total: 12, system: "Checkout DS")
                .frame(width: 278)
            VStack(spacing: SH.Space.l) {
                SHDesignSystemCard(name: "Shepherd Design", source: "Built into Shepherd", count: "1 design", tag: "Built-in")
                SHDesignSystemCard(name: "Checkout DS", source: "came with Checkout funnel", count: "after the boards", dashed: true)
                SHDesignStartCard(symbol: "square.and.arrow.down", title: "Import a project", line: "from Claude Design",
                                  note: "a ZIP or folder you exported", chosen: false)
            }
            .frame(width: 376)
        }
        .padding(SH.Space.l)
    }
}

#Preview("Drop target") {
    SHPreviewBoth {
        SHDesignsDropTarget()
            .frame(width: 520, height: 240)
    }
}
