import Foundation
import ShepherdCore
import ShepherdProtocol
import WebKit

/// One design's rendering sandbox, shared by every board view of that design: a non-persistent
/// website data store (nothing a board stores outlives it or reaches another design) and the
/// `shepherd-design://<design>/` scheme serving the design's folder.
@MainActor
public final class DesignSurface {
    public let designID: DesignID
    /// The design's folder, `<support>/designs/<id>/`: boards come from its `project/`, uploads
    /// from its `assets/`.
    public let folder: URL
    public let network: DesignSandbox.Network

    let dataStore: WKWebsiteDataStore
    let schemeHandler: DesignSchemeHandler

    public nonisolated static let scheme = DesignRoute.scheme

    public init(designID: DesignID, folder: URL, network: DesignSandbox.Network = .googleFonts) {
        self.designID = designID
        self.folder = folder
        self.network = network
        dataStore = .nonPersistent()
        schemeHandler = DesignSchemeHandler(host: designID.rawValue, folder: folder, network: network)
    }

    /// Where a board loads from: `shepherd-design://<design>/project/<path>`.
    public func url(for board: DesignPath) -> URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = designID.rawValue
        components.path = "/project/" + board.rawValue
        return components.url!
    }

    /// The board's path when `url` names a board of this design, as an in-project link does.
    public func board(at url: URL) -> DesignPath? {
        guard case .project(let segments) = DesignRoute(url: url, host: designID.rawValue) else { return nil }
        return DesignPath(segments.joined(separator: "/"))
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
        configuration.dataDetectorTypes = []
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = false
        #endif
        return configuration
    }
}
