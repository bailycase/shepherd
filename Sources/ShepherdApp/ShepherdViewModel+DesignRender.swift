import Foundation
import ShepherdProtocol

// A design agent's `board_render` (docs/designs.md › Rendering for the agent): the server reads the
// board's files and hands the job here; the app draws it off screen, one at a time, and answers a
// picture sized for pi's session.

extension ShepherdViewModel {
    func installDesignRenderHandler() {
        server.onDesignRender = { [weak self] job, respond in
            MainActor.assumeIsolated {
                guard let self else {
                    respond(.failure(DesignRenderFailure(code: "render_unavailable", message: "The workspace is gone.")))
                    return
                }
                Task { @MainActor in
                    do {
                        respond(.success(try await self.designRendering.picture(for: job)))
                    } catch let failure as DesignRenderFailure {
                        respond(.failure(failure))
                    } catch {
                        respond(.failure(DesignRenderFailure(code: "render_failed", message: "\(job.path) couldn't be drawn: \(error)")))
                    }
                }
            }
        }
    }
}
