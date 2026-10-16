import Foundation
import ShepherdSessions
import ShepherdProtocol

/// View helpers shared by the children extension's in-pi fleet view
/// (`shepherd-children-ui.ts` imports them). Installed beside the children extension by
/// `ChildrenExtension`. Extensions/shepherd-inspect.mjs is canonical; keep this literal
/// byte-identical to it.
enum InspectExtension {
    static var extensionSource: String { EmbeddedExtensions.source("shepherd-inspect.mjs") }
}
