import SwiftUI

// Deleting and importing designs (DesignLifecycleStates), light and dark.

#Preview("Delete design dialog") {
    SHPreviewBoth {
        SHDesignSheet(title: "Delete “Checkout funnel”?") {
            SHDesignAlertWarning("The design agent is drawing 2 boards right now. Deleting stops it, and what it’s drawing is lost.")
            SHDesignSheetFacts {
                SHDesignSheetFact("Goes", Text("4 boards, their 23 versions and 2 comments"))
                SHDesignSheetFact(nil, Text("The design agent’s chat for this design"))
                SHDesignSheetFact("Stays", Text("\(SHDesignAlertMessage.mono("acme-web")), the design system it uses"))
            }
            SHDesignSheetNote("You can undo right after.")
        } leading: {
            Toggle("Don’t ask again", isOn: .constant(false)).toggleStyle(.shSheetCheck)
        } actions: {
            Button("Cancel") {}.buttonStyle(.shSheet(.quiet))
            Button("Stop and delete") {}.buttonStyle(.shSheet(.danger))
        }
    }
}

#Preview("Import error dialog") {
    SHPreviewBoth {
        SHDesignSheet(title: "Couldn’t import “checkout-funnel”") {
            SHDesignAlertMessage("3 boards point to files outside the project folder. Shepherd only reads what’s inside the project, so it stopped.")
            SHDesignAlertLinks([.init(from: "boards/hero.html", to: "../shared/logo.svg"),
                                .init(from: "boards/pricing.html", to: "../../fonts/Inter.woff2"),
                                .init(from: "boards/footer.html", to: "/Users/sam/Desktop/bg.png")])
            SHDesignSheetNote("Nothing was imported, and nothing was left behind.")
        } actions: {
            Button("OK") {}.buttonStyle(.shSheet(.pill))
        }
    }
}

#Preview("Undo toast") {
    SHPreviewBoth {
        VStack(spacing: SH.Space.l) {
            SHUndoToast(message: Text("Deleted \(Text("Checkout funnel").fontWeight(.semibold))."), actionTitle: "Undo",
                        action: {}, dismiss: {})
            SHUndoToast(tone: .failed,
                        message: Text("Couldn’t delete \(Text("Checkout funnel").fontWeight(.semibold)). The files could not be removed."),
                        actionTitle: "Try again", action: {}, dismiss: {})
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
                SHDesignSystemCard(name: "Shepherd UI", source: "Built into Shepherd", count: "1 design")
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
