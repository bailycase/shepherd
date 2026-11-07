import SwiftUI
import ShepherdUI

/// Dimensions for the Files tab (FileOpenSplit board).
extension AppLayout {
    enum Files {
        /// The file viewer header bar height.
        static let headerHeight: CGFloat = 40
        /// Status bar height under the editor (legend, caret, language, indentation).
        static let statusBarHeight: CGFloat = 28
        /// A changed line's bar in the gutter, and in the status bar's legend.
        static let markWidth: CGFloat = 2
        static let legendMarkHeight: CGFloat = 10
        /// A tab's unsaved-edits dot.
        static let dirtyDotSize: CGFloat = 6
        /// The active tab's lantern rule along its top.
        static let activeTabRule: CGFloat = 2
        /// How often an open editor checks its file on disk.
        static let diskCheckInterval: Duration = .seconds(2)
        /// The pause in typing before the editor highlights again.
        static let rehighlightDelay: Duration = .milliseconds(300)
        /// Tab strip height for open files.
        static let tabHeight: CGFloat = 36
        /// Default tree panel width.
        static let treeWidth: CGFloat = 260
        /// Minimum tree panel width during resize.
        static let treeMinWidth: CGFloat = 160
        /// Minimum viewer width so the code area is never squeezed out.
        static let viewerMinWidth: CGFloat = 200
        /// Code line height (board: 20px at code font size).
        static let lineHeight: CGFloat = 20
        /// Tree row height (board: 24px rows).
        static let treeRowHeight: CGFloat = 24
        /// Tree indentation per depth level.
        static let treeIndent: CGFloat = 16
        /// Tree disclosure/file icon size.
        static let treeIconSize: CGFloat = 14
        /// Tree disclosure chevron font size.
        static let treeChevronSize: CGFloat = 9
        /// Tree file icon font size.
        static let treeFileIconSize: CGFloat = 11
        /// Tree row font size (board: 12.5px UI weight).
        static let treeRowFontSize: CGFloat = 12.5
        /// Filter field height.
        static let filterHeight: CGFloat = 28
        /// Space header height.
        static let spaceHeaderHeight: CGFloat = 28
        /// Footer height.
        static let footerHeight: CGFloat = 32
        /// Filter search icon size.
        static let filterIconSize: CGFloat = 11
        /// Filter text font size.
        static let filterFontSize: CGFloat = 12
        /// Symlink indicator icon size.
        static let symlinkIconSize: CGFloat = 9
        /// Abbreviated path max width.
        static let pathMaxWidth: CGFloat = 130
        /// Space name font size.
        static let spaceNameFontSize: CGFloat = 12.5
        /// Refresh icon size.
        static let refreshIconSize: CGFloat = 10
        /// Show-tree button icon size.
        static let showTreeIconSize: CGFloat = 11
        /// Show-tree button padding.
        static let showTreePadding: CGFloat = 8
        /// Image preview max dimension (thumbnail to cap memory).
        static let imageMaxDimension: CGFloat = 2048
        /// Empty state icon size.
        static let emptyIconSize: CGFloat = 28
        /// Error icon size.
        static let errorIconSize: CGFloat = 24
        static let messageMaxWidth: CGFloat = 280
        /// Tab close button size.
        static let tabCloseSize: CGFloat = 14
        /// Toggle tree button size (board: sidebar.right icon button).
        static let toggleTreeSize: CGFloat = 28
        /// Tab close X icon font size.
        static let tabCloseFontSize: CGFloat = 8
        /// Code viewer NSTextView font size (board: code 12px).
        static let codeFontSize: CGFloat = 12
        /// Keep tab indentation readable without modifying the source text.
        static let tabColumns: CGFloat = 4
        /// Toolbar icon-button font size (word wrap, markdown preview).
        static let toolbarIconSize: CGFloat = 11
        /// Toolbar icon-button tap target.
        static let toolbarButtonSize: CGFloat = 28
    }
}
