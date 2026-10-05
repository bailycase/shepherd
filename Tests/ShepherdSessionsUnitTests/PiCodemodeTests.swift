import Foundation
import Testing
@testable import ShepherdSessions

@Suite("Native codemode settings")
struct PiCodemodeTests {
    @Test func switchingAndInheritingPreserveUnrelatedSettings() throws {
        let original: [String: Any] = ["extensions": ["./my-extension.ts"], "defaultTools": ["+grep"],
                                       "codemode": ["inlineBudget": 400], "thinkingLevel": "high"]
        let on = try PiCodemode.setting(true, in: original)
        #expect(on["extensions"] as? [String] == ["./my-extension.ts", "-builtin:codemode"])
        #expect(on["defaultTools"] as? [String] == ["+grep"])
        #expect(PiCodemode.projectOverride(in: on) == true)
        let off = try PiCodemode.setting(false, in: on)
        #expect(off["extensions"] as? [String] == ["./my-extension.ts", "-builtin:codemode"])
        #expect(off["defaultTools"] as? [String] == ["+grep"])
        #expect(PiCodemode.projectOverride(in: off) == false)
        let inherited = try PiCodemode.setting(nil, in: off)
        #expect(NSDictionary(dictionary: inherited).isEqual(to: original))
        #expect(PiCodemode.projectOverride(in: inherited) == nil)
        #expect(try PiCodemode.setting(nil, in: PiCodemode.setting(true, in: [:])).isEmpty)
    }

    @Test(arguments: [[String](), ["read"], ["read", "bash"], ["codemode"], ["codemode", "+grep"], ["+grep", "-codemode"]])
    func toolSelectionsNeverChangeWhenSwitchingCodemode(_ original: [String]) throws {
        for enabled: Bool? in [true, false, nil] {
            let changed = try PiCodemode.setting(enabled, in: ["defaultTools": original])
            #expect(changed["defaultTools"] as? [String] == original)
        }
    }

    @Test func invalidFieldsAreRejectedInsteadOfDiscarded() {
        for settings: [String: Any] in [["extensions": "wrong"], ["codemode": false], ["codemode": ["enabled": 1]]] {
            #expect(throws: PiHomeError.self) { try PiCodemode.setting(true, in: settings) }
        }
    }
}
