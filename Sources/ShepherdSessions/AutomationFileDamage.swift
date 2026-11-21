import Foundation

/// An automation file (run history, trigger state) the host can't read. Its text is what the
/// Automations page shows: which file, why, and that it's untouched. Writers throw it.
struct AutomationFileDamage: Error, CustomStringConvertible, Equatable {
    let description: String

    /// `noun` names the file for a person ("run history").
    init(_ noun: String, at url: URL, original: Data?, error: any Error) {
        let reason: String
        if original != nil {
            reason = "Invalid \(noun) JSON"
        } else if (error as? CocoaError)?.code == .fileReadNoPermission {
            reason = "Permission denied reading the \(noun) file"
        } else {
            reason = "Couldn't read the \(noun) file"
        }
        description = "\(reason): \(url.path)"
    }
}
