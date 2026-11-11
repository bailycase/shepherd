import Foundation
import ShepherdProtocol
import ShepherdSessions

// A design agent's `board_render`: the host reads the board's files and relays the job here
// (`DesignRelayJob`); the app draws it off screen, one at a time, and answers a picture sized
// for pi's session. A design's `design_export` and a reference's copy come the same way.

extension ShepherdViewModel {
    func installDesignRenderHandler() {
        // The background host on this Mac has no web view: its agents' boards are drawn here.
        remoteHosts.onDesignRelay = { [weak self] client, token, job in
            let answer = { (result: DesignRelayResult) in client.designRelayAnswer(token: token, result: result) }
            guard let self else { return answer(.failed(code: "render_unavailable", message: "The workspace is gone.")) }
            Task { @MainActor in
                switch job {
                case .render(let job):
                    do { answer(.rendered(try await self.designRendering.picture(for: job))) }
                    catch let failure as DesignRenderFailure { answer(.failed(code: failure.code, message: failure.message)) }
                    catch { answer(.failed(code: "render_failed", message: "\(job.path) couldn't be drawn: \(error)")) }
                case .export(let job):
                    do {
                        try await self.designRendering.exportAgent(job)
                        answer(.exported)
                    } catch { answer(.failed(code: "export_failed", message: String(describing: error))) }
                case .capture(let request):
                    do {
                        guard let files = request.files else {
                            throw DesignReferenceError("version_gone", "The pinned rendering inputs are no longer kept. Pick the piece again.")
                        }
                        answer(.captured(try await self.designRendering.capture(request, files: files)))
                    } catch let error as DesignReferenceError {
                        answer(.failed(code: error.code, message: error.message))
                    } catch {
                        answer(.failed(code: "render_failed", message: (error as? LocalizedError)?.errorDescription ?? "\(error)"))
                    }
                }
            }
        }
    }
}
