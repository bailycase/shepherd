import Foundation
import ShepherdProtocol

/// View helpers shared by the children extension's in-pi fleet view
/// (`shepherd-children-ui.ts` imports them). Installed beside the children extension by
/// `ChildrenExtension`. Extensions/shepherd-inspect.mjs is canonical; keep this literal
/// byte-identical to it.
public enum InspectExtension {
    public static var extensionSource: String { EmbeddedExtensions.source("shepherd-inspect.mjs") }
}
