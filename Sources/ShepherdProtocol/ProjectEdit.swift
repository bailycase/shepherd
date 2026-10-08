import ShepherdCore

/// Editing a registration never moves data unless folderAction explicitly asks for it.
public struct ProjectEdit: Codable, Hashable, Sendable {
    public enum FolderAction: String, Codable, Sendable { case none, move, copy }
    public var name: String?
    /// Omitted: preserve organization. Empty string: make top-level. Otherwise a local SpaceID.
    public var parentProjectID: String?
    public var folderAction: FolderAction
    public var destinationPath: String?

    public init(name: String? = nil, parentProjectID: String? = nil, folderAction: FolderAction = .none, destinationPath: String? = nil) {
        self.name = name
        self.parentProjectID = parentProjectID
        self.folderAction = folderAction
        self.destinationPath = destinationPath
    }

    private enum CodingKeys: String, CodingKey { case name, parentProjectID, folderAction, destinationPath }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        parentProjectID = try c.decodeIfPresent(String.self, forKey: .parentProjectID)
        folderAction = try c.decodeIfPresent(FolderAction.self, forKey: .folderAction) ?? .none
        destinationPath = try c.decodeIfPresent(String.self, forKey: .destinationPath)
    }
}
