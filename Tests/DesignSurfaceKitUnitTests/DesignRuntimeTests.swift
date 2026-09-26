import CryptoKit
import Foundation
import Testing
@testable import DesignSurfaceKit

/// The scripts a board runs with: React pinned to what was vetted, and the runtime after it.
@Suite struct DesignRuntimeTests {
    /// React 18.3.1's UMD production builds from npm (`react` and `react-dom` 18.3.1, whose
    /// tarballs matched the registry's sha512 integrity when vendored). A new build must be
    /// vetted and its hash pinned here.
    @Test(arguments: [
        ("react/react.production.min.js", "d949f1c3687aedadcedac85261865f29b17cd273997e7f6b2bfc53b2f9d4c4dd"),
        ("react/react-dom.production.min.js", "35f4f974f4b2bcd44da73963347f8952e341f83909e4498227d4e26b98f66f0d"),
        ("react/LICENSE", "52412d7bc7ce4157ea628bbaacb8829e0a9cb3c58f57f99176126bc8cf2bfc85"),
    ])
    func theVendoredReactIsTheOnePinned(_ path: String, _ sha256: String) throws {
        let data = try #require(DesignRuntime.resource(path), "\(path) ships")
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sha256)
    }

    @Test func reactShipsWithItsMITLicense() throws {
        let license = String(decoding: try #require(DesignRuntime.resource("react/LICENSE")), as: UTF8.self)
        #expect(license.hasPrefix("MIT License"))
        for name in DesignRuntime.reactFiles {
            let script = String(decoding: try #require(DesignRuntime.resource("react/" + name)), as: UTF8.self)
            #expect(script.contains("@license React") && script.contains("\"18.3.1\""), "\(name)")
        }
    }

    @Test func supportScriptIsReactThenTheRuntime() throws {
        let script = String(decoding: try #require(DesignRuntime.supportScript), as: UTF8.self)
        let react = try #require(script.range(of: "react.production.min.js"))
        let dom = try #require(script.range(of: "react-dom.production.min.js"))
        let runtime = try #require(script.range(of: "shepherd-dc-runtime.js"))
        #expect(react.lowerBound < dom.lowerBound && dom.lowerBound < runtime.lowerBound)
        #expect(DesignRuntime.bridgeScript.contains("shepherdDesign"))
    }
}
