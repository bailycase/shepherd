import Foundation
import ShepherdProtocol

/// Decodes one recorded pi record (or any wire value) from its JSON text.
func decode<T: Decodable>(_ json: String, as type: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

/// A private temporary directory for tests whose unit is a file format. Removed by the caller.
func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("shepherd-unit-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func posixPermissions(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
}
