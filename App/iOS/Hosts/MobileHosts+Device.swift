import UIKit

extension MobileHosts.DeviceDescription {
    /// This device as a fleet's Macs list it: its name, and whether it is a phone or an iPad.
    @MainActor static var current: Self {
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let name = UIDevice.current.name
        return Self(name: name.isEmpty ? (pad ? "iPad" : "iPhone") : name, kind: pad ? .ipad : .iphone)
    }
}
