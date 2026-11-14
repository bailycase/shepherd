import Darwin
import Foundation
import ShepherdProtocol
import ShepherdRemote
import dnssd

/// Advertises this host as `_shepherd._tcp` while its listener is open, so another Mac's Add a Mac list
/// can find it. The listener is the host's own (`SessionServer.startRemoteListener`); this only
/// registers its port with the system's mDNS responder, which needs no socket here and no
/// Local Network prompt for advertising. The TXT record says only what a person sees in the
/// list: a hash of the id (so a Mac skips its own entry), the name and the build.
final class FleetDiscovery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "shepherd.fleet.discovery")
    private var ref: DNSServiceRef?

    /// Whether the registration is live.
    private(set) var isAdvertising = false

    /// Registers (again) with the current name and port; an earlier registration is dropped.
    func advertise(name: String, hostID: UUID, build: String?, port: UInt16) {
        stop()
        let txt = Self.txtRecord(hostID: hostID, name: name, build: build)
        var created: DNSServiceRef?
        let status = txt.withUnsafeBytes { raw in
            DNSServiceRegister(&created, 0, 0, Self.instanceName(name), FleetProtocol.bonjourType, nil, nil,
                               port.bigEndian, UInt16(txt.count), raw.baseAddress, nil, nil)
        }
        guard status == kDNSServiceErr_NoError, let created else {
            ShepherdLog.warning("fleet: Bonjour registration failed (\(status))")
            return
        }
        DNSServiceSetDispatchQueue(created, queue)
        ref = created
        isAdvertising = true
    }

    func stop() {
        guard let ref else { return }
        DNSServiceRefDeallocate(ref)
        self.ref = nil
        isAdvertising = false
    }

    deinit { stop() }

    /// A DNS-SD instance name is at most 63 bytes of UTF-8.
    static func instanceName(_ name: String) -> String { truncated(name, bytes: 63) }

    static func truncated(_ text: String, bytes: Int) -> String {
        var result = ""
        for character in text {
            guard result.utf8.count + String(character).utf8.count <= bytes else { break }
            result.append(character)
        }
        return result
    }

    /// The TXT record's `key=value` entries, each length prefixed.
    static func txtRecord(hostID: UUID, name: String, build: String?) -> Data {
        var entries = ["v=1", "id=\(FleetProtocol.advertisedIDHash(hostID))", "name=\(truncated(name, bytes: 100))"]
        if let build { entries.append("build=\(truncated(build, bytes: 40))") }
        var data = Data()
        for entry in entries {
            let bytes = Array(entry.utf8)
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        return data
    }
}
