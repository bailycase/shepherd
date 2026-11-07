import Foundation
import ShepherdProtocol

/// Boards drawn for a host with no web view: `board_render`, `design_export` and a reference's
/// copy go to the app connected over `host.sock` (`relayDesign`), which draws them as it does in
/// process. With no app connected they are refused, saying Shepherd's window is closed.
extension SessionServer {
    static let windowClosed = "Drawing a design needs Shepherd's window, and it is closed. Open Shepherd and try again."

    /// Installs the three handlers. Once per server, by the background host.
    @MainActor
    public func relayDesignDrawingToApp() {
        onDesignRender = { [weak self] job, respond in
            guard let self else { return respond(.failure(DesignRenderFailure(code: "render_unavailable", message: Self.windowClosed))) }
            relayDesign(.render(job)) { result in
                switch result {
                case .rendered(let rendered)?: respond(.success(rendered))
                case .failed(let code, let message)?: respond(.failure(DesignRenderFailure(code: code, message: message)))
                default: respond(.failure(DesignRenderFailure(code: "render_unavailable", message: Self.windowClosed)))
                }
            }
        }
        onDesignExport = { [weak self] job, respond in
            guard let self else { return respond(.failure(DesignRenderFailure(code: "export_unavailable", message: Self.windowClosed))) }
            relayDesign(.export(job)) { result in
                switch result {
                case .exported?: respond(.success(()))
                case .failed(let code, let message)?: respond(.failure(DesignRenderFailure(code: code, message: message)))
                default: respond(.failure(DesignRenderFailure(code: "export_unavailable", message: Self.windowClosed)))
                }
            }
        }
        onDesignReferenceCapture = { [weak self] request, respond in
            guard let self else { return respond(.failure(.noRenderer)) }
            relayDesign(.capture(request)) { result in
                switch result {
                case .captured(let captured)?: respond(.success(captured))
                case .failed(let code, let message)?: respond(.failure(DesignReferenceError(code, message)))
                default: respond(.failure(DesignReferenceError(DesignReferenceError.noRenderer.code, Self.windowClosed)))
                }
            }
        }
    }
}
