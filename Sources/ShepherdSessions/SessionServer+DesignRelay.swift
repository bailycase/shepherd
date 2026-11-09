import Foundation
import ShepherdProtocol

/// Boards drawn for a host with no web view: `board_render` (and `board_interact`, a render with
/// steps), `design_export` and a reference's copy go to the app connected over `host.sock`
/// (`relayDesign`), which draws them as it does in process. With no app connected they are
/// refused, saying so.
extension SessionServer {
    static let appNotOpen = "Drawing a design needs the Shepherd app, which isn't open. Open Shepherd and try again."
    static let appTooOld = "The Shepherd app open is older than its background host and can't draw designs. Quit and reopen Shepherd."
    static let appLeftWhileDrawing = "The Shepherd app disconnected from its background host while drawing. Try again."

    /// Installs the three handlers. Once per server, by the background host.
    @MainActor
    public func relayDesignDrawingToApp() {
        // Jobs a previous run handed out and never got back.
        try? FileManager.default.removeItem(at: designRelayFolder)
        onDesignRender = { [weak self] job, respond in
            guard let self else { return respond(.failure(DesignRenderFailure(code: "render_unavailable", message: Self.appNotOpen))) }
            relayDesign(.render(job), code: "render_unavailable") { result in
                switch result {
                case .rendered(let rendered): respond(.success(rendered))
                case .failed(let code, let message): respond(.failure(DesignRenderFailure(code: code, message: message)))
                default: respond(.failure(DesignRenderFailure(code: "render_failed", message: "Shepherd's app answered with no picture.")))
                }
            }
        }
        onDesignExport = { [weak self] job, respond in
            guard let self else { return respond(.failure(DesignRenderFailure(code: "export_unavailable", message: Self.appNotOpen))) }
            relayDesign(.export(job), code: "export_unavailable") { result in
                switch result {
                case .exported: respond(.success(()))
                case .failed(let code, let message): respond(.failure(DesignRenderFailure(code: code, message: message)))
                default: respond(.failure(DesignRenderFailure(code: "export_failed", message: "Shepherd's app answered with no export.")))
                }
            }
        }
        onDesignReferenceCapture = { [weak self] request, respond in
            guard let self else { return respond(.failure(.noRenderer)) }
            relayDesign(.capture(request), code: DesignReferenceError.noRenderer.code) { result in
                switch result {
                case .captured(let captured): respond(.success(captured))
                case .failed(let code, let message): respond(.failure(DesignReferenceError(code, message)))
                default: respond(.failure(DesignReferenceError(DesignReferenceError.noRenderer.code, "Shepherd's app answered with no copy.")))
                }
            }
        }
    }
}
