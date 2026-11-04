import Foundation
import ShepherdProtocol

extension RemoteHostClient {
    /// The host serves Issues & PRs (`RemoteProtocol.forgeCapability`).
    public var servesForge: Bool { capabilities.contains(RemoteProtocol.forgeCapability) }

    /// One Issues & PRs request to the host, answered as `SessionServer.forge` answers the Mac:
    /// the same result, or a `ForgeError` in words (gh's own, `unsupported` from an older host,
    /// `unreachable` when the connection failed). Never throws.
    public func forge(_ request: RemoteForgeRequest) async -> Result<RemoteForgeResult, ForgeError> {
        guard servesForge else {
            return .failure(ForgeError(.unsupported, "Update Shepherd on the host to see its issues and pull requests from here."))
        }
        do {
            // A detail runs several gh commands of up to 15 s each, side by side.
            let reply = try await self.request(timeout: 45) { .forge(id: $0, request: request) }
            switch reply {
            case .forgeResult(_, let result): return .success(result)
            case .error(_, let code, let message): return .failure(ForgeError(ForgeError.Code(rawValue: code) ?? .failed, message))
            default: return .failure(ForgeError(.failed, "The host answered something unexpected."))
            }
        } catch RemoteHostClientError.rejected(let code, let message) {
            return .failure(ForgeError(ForgeError.Code(rawValue: code) ?? .failed, message))
        } catch {
            let message = request.isChange
                ? "Lost the host before it answered; the change may still have happened. Reload to see."
                : "Couldn't reach the host."
            return .failure(ForgeError(.unreachable, message))
        }
    }
}
