import SwiftUI
import ShepherdUI

extension MobileLayout {
    /// A level of the Files tree (DuoSidePaneTabs: a folder's files start past its chevron).
    static let fileTreeIndent: CGFloat = 22
    /// The column a row's chevron or page centers in.
    static let fileTreeIcon: CGFloat = SH.Space.xl
}

// The iPad's Files pane beside the thread (iPadPaneFiles): the tree, then the open files as tabs over an editor.
extension MobileLayout {
    /// The pane splits into tree and editor from this width; narrower, a file opens in place of the tree.
    static let filesSplitMinWidth: CGFloat = 520
    static let filesTreeColumn: CGFloat = 210
    /// A level of the split tree, and the chevron's column a file's icon lines up past.
    static let filesTreeLevel: CGFloat = 14
    static let filesChevron: CGFloat = 9
    static let filesTabHeight: CGFloat = 42
    static let filesPathBarHeight: CGFloat = 44
    static let filesStatusBarHeight: CGFloat = 28
    /// The active tab's lantern rule along its top.
    static let filesActiveTabRule: CGFloat = 2
    static let filesDirtyDot: CGFloat = 7
    /// A line's mark, and the legend's sample of it.
    static let fileMarkWidth: CGFloat = 3
    static let filesLegendMarkHeight: CGFloat = 11
    static let fileCodeTextSize: CGFloat = 13
    static let fileCodeLineHeight: CGFloat = 24
    static let fileCodeNumberSize: CGFloat = 10.5
    /// The numbers' column; the mark sits 8pt past it, the text 10pt past the mark.
    static let fileCodeGutter: CGFloat = 36
    static let fileCodeMarkGap: CGFloat = 8
    static let fileCodeTextGap: CGFloat = 10
    /// How long an unwrapped line may run before it wraps after all.
    static let unwrappedLineWidth: CGFloat = 20_000
    /// Syntax colors come back after this pause in typing.
    static let fileRestyleDelay: Duration = .milliseconds(250)
}
