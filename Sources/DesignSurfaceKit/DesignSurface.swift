import Foundation
import ShepherdCore
import ShepherdProtocol
import WebKit

/// One design's rendering sandbox, shared by every board view of that design: a non-persistent
/// website data store (nothing a board stores outlives it or reaches another design) and the
/// `shepherd-design://<design>/` scheme serving the design's folder, or files held in memory.
@MainActor
public final class DesignSurface {
    public let designID: DesignID
    /// The design's folder, `<support>/designs/<id>/`: boards come from its `project/`, uploads
    /// from its `assets/`. Nil for a surface over files in memory or a file source.
    public let folder: URL?
    public let network: DesignSandbox.Network

    let dataStore: WKWebsiteDataStore
    let schemeHandler: DesignSchemeHandler

    public nonisolated static let scheme = DesignRoute.scheme

    public init(designID: DesignID, folder: URL, network: DesignSandbox.Network = .googleFonts) {
        self.designID = designID
        self.folder = folder
        self.network = network
        dataStore = .nonPersistent()
        schemeHandler = DesignSchemeHandler(host: designID.rawValue, files: .folder(folder), network: network)
    }

    /// A surface over files held in memory, by their project path (`tokens.css`,
    /// `components/Button.html`, a board written for them): a design system's files drawn as
    /// specimens. The same rules hold: each path by the file grammar, the runtime at any
    /// `support.js`, and nothing else (no uploads).
    public init(designID: DesignID, files: [String: Data], network: DesignSandbox.Network = .googleFonts) {
        self.designID = designID
        folder = nil
        self.network = network
        dataStore = .nonPersistent()
        schemeHandler = DesignSchemeHandler(host: designID.rawValue, files: .memory(files), network: network)
    }

    /// A surface over a file source: a remote host's design, its files fetched by hash and
    /// cached on this device (`RemoteDesignSource`). Rendering happens here, never on the host.
    /// The same rules hold: each path by the file grammar, the runtime at any `support.js`, and
    /// uploads only as the source answers them for their id.
    public init(designID: DesignID, source: any DesignFileSource, network: DesignSandbox.Network = .googleFonts) {
        self.designID = designID
        folder = nil
        self.network = network
        dataStore = .nonPersistent()
        schemeHandler = DesignSchemeHandler(host: designID.rawValue, files: .source(source), network: network)
    }

    /// Where a board loads from: `shepherd-design://<design>/project/<path>`.
    public func url(for board: DesignPath) -> URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = designID.rawValue
        components.path = "/project/" + board.rawValue
        return components.url!
    }

    /// The board's path when `url` names a board of this design, as an in-project link does
    /// (relative to the board, or from the canvas root with a leading `/`).
    public func board(at url: URL) -> DesignPath? {
        DesignRoute.linkedPath(url, host: designID.rawValue).flatMap(DesignPath.init)
    }

    func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: Self.scheme)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.upgradeKnownHostsToHTTPS = true
        #if os(iOS)
        // iPad browses as a desktop by default, where a page narrower than 980 lays out 980 wide
        // whatever its viewport says: a phone board drawn live on the canvas would shrink.
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        configuration.dataDetectorTypes = []
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = false
        #endif
        return configuration
    }
}
