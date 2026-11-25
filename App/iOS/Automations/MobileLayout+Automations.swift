import SwiftUI
import ShepherdUI

extension MobileLayout {
    /// The iPad list beside an automation's detail (iPadAutomations).
    static let automationsListWidth: CGFloat = 360
    /// The prompt's editor, before it grows.
    static let automationPromptMinHeight: CGFloat = 140
    /// The detail's readable measure on iPad.
    static let automationDetailMaxWidth: CGFloat = 640

    /// A fact's label column and text (iPadAutomations' "Status", "Runs on").
    static let automationFactLabelWidth: CGFloat = 110
    static let automationFactSize: CGFloat = 14
    /// The detail's action pill, and the rule between its words.
    static let automationActionHeight: CGFloat = 52
    static let automationActionDivider: CGFloat = 20
}
