import SwiftUI

// Deleting and importing designs (DesignLifecycleStates), light and dark.

#Preview("Delete design dialog") {
    NWPreviewBoth {
        NWDesignAlert(symbol: "trash", title: "Delete “Checkout funnel dashboard”?") {
            NWDesignAlertList {
                NWDesignAlertLine(symbol: "xmark", role: .goes,
                                  Text("\(NWDesignAlertMessage.strong("4 boards")), their 23 versions and 2 comments"))
                NWDesignAlertLine(symbol: "xmark", role: .goes, Text("The design agent’s chat for this design"))
                NWDesignAlertLine(symbol: "checkmark", role: .stays,
                                  Text("Stays: \(NWDesignAlertMessage.mono("acme-web")), the design system it uses"))
            }
            Text("You can undo right after.")
                .font(.nwSans(NWDesignMetrics.alertMessageSize))
                .foregroundStyle(Color.nw.textTertiary)
            NWDesignAlertWarning("The design agent is drawing 2 boards right now. Deleting stops it, and what it’s drawing is lost.")
        } actions: {
            Button("Cancel") {}.buttonStyle(.nw(.secondary))
            Button("Stop and delete") {}.buttonStyle(.nw(.dangerFill))
        }
    }
}

#Preview("Import error dialog") {
    NWPreviewBoth {
        NWDesignAlert(symbol: "exclamationmark.triangle", title: "Couldn’t import “checkout-funnel”", width: NWDesignMetrics.alertWideWidth) {
            NWDesignAlertMessage("3 boards point to files outside the project folder. Shepherd only reads what’s inside the project, so it stopped.")
            NWDesignAlertLinks([.init(from: "boards/hero.html", to: "../shared/logo.svg"),
                                .init(from: "boards/pricing.html", to: "../../fonts/Inter.woff2"),
                                .init(from: "boards/footer.html", to: "/Users/sam/Desktop/bg.png")])
            NWDesignAlertReassurance("Nothing was imported.")
        } actions: {
            Button("OK") {}.buttonStyle(.nw(.primary))
        }
    }
}

#Preview("Undo toast") {
    NWPreviewBoth {
        VStack(spacing: NW.Space.l) {
            NWUndoToast(message: Text("Deleted \(Text("Checkout funnel dashboard").fontWeight(.semibold))."), actionTitle: "Undo",
                        actionSymbol: "arrow.uturn.backward", action: {}, dismiss: {})
            NWUndoToast(tone: .failed,
                        message: Text("Couldn’t delete \(Text("Checkout funnel dashboard").fontWeight(.semibold)). build-01, where it’s saved, didn’t answer, so it’s back."),
                        actionTitle: "Try again", actionSymbol: "arrow.clockwise", action: {}, dismiss: {})
        }
        .padding(NW.Space.l)
    }
}

#Preview("Import cards") {
    NWPreviewBoth {
        HStack(alignment: .top, spacing: NW.Space.xl) {
            NWImportingCard(title: "Checkout funnel", done: 7, total: 12, system: "Checkout DS")
                .frame(width: 278)
            VStack(spacing: NW.Space.l) {
                NWDesignSystemCard(name: "Night Watch", source: "Built into Shepherd", count: "1 design", tag: "Built-in")
                NWDesignSystemCard(name: "Checkout DS", source: "came with Checkout funnel", count: "after the boards", dashed: true)
                NWDesignStartCard(symbol: "square.and.arrow.down", title: "Import a project", line: "from Claude Design",
                                  note: "a ZIP or folder you exported", chosen: false)
            }
            .frame(width: 376)
        }
        .padding(NW.Space.l)
    }
}

#Preview("Drop target") {
    NWPreviewBoth {
        NWDesignsDropTarget()
            .frame(width: 520, height: 240)
    }
}
