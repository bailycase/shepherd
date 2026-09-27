import SwiftUI

// DesignRefStates: every chip state (the other hosts' among them), the preview, the @ picker's
// stages, the board actions, the sheets, the toasts, the agent's line and the thread's pin.

#Preview("Design references") {
    NWPreviewBoth {
        ScrollView { NWDesignReferenceSpecimens() }
    }
    .frame(width: 2600, height: 2400)
}
