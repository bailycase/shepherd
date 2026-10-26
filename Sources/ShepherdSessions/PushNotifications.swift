import Foundation
import ShepherdCore
import ShepherdProtocol

/// Owned by SessionServer's queue. Only registrations persist; deliveries are best-effort,
/// bounded, never retried or replayed. The injected transport returns a cancellation closure.
final class PushNotifications: @unchecked Sendable {
    typealias Transport = (URLRequest, @escaping @Sendable (Int?) -> Void) -> (() -> Void)
    enum Kind: String, Codable { case done, error, needsAnswer }
    private struct Event: Encodable {
        let eventID = UUID()
        let agentID: AgentID
        let kind: Kind
    }
    private struct Delivery {
        let registrationID: String
        let cancel: () -> Void
    }
    private let file: URL
    private let queue: DispatchQueue
    private(set) var registrations: [String: RemotePushRegistration] = [:]
    private var deliveries: [UUID: Delivery] = [:]
    private var window = Date.distantPast
    private var eventCount = 0
    var transport: Transport
    var now: () -> Date = Date.init

    init(file: URL, queue: DispatchQueue) {
        self.file = file
        self.queue = queue
        transport = { request, finished in
            let task = PushHTTP.session.dataTask(with: request) { _, response, _ in
                finished((response as? HTTPURLResponse)?.statusCode)
            }
            task.resume()
            return { task.cancel() }
        }
        if let data = try? Data(contentsOf: file), data.count <= 32_768,
           let saved = try? JSONDecoder().decode([RemotePushRegistration].self, from: data), saved.count <= 16 {
            for registration in saved where Self.valid(registration) {
                let id = UUID(uuidString: registration.id)!.uuidString
                registrations[id] = RemotePushRegistration(id: id, sendToken: registration.sendToken)
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    static func valid(_ registration: RemotePushRegistration) -> Bool {
        UUID(uuidString: registration.id) != nil && registration.sendToken.utf8.count == 64
            && registration.sendToken.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    func register(_ registration: RemotePushRegistration) throws {
        guard Self.valid(registration) else { throw Failure.invalid }
        let id = UUID(uuidString: registration.id)!.uuidString
        guard registrations[id] != nil || registrations.count < 16 else { throw Failure.full }
        var next = registrations
        next[id] = RemotePushRegistration(id: id, sendToken: registration.sendToken)
        try persist(next)
        cancel(id)
        registrations = next
    }

    func unregister(_ rawID: String) throws {
        guard let id = UUID(uuidString: rawID)?.uuidString else { throw Failure.invalid }
        // Revocation takes effect even if disk fails; the caller gets an error and may retry.
        cancel(id)
        registrations.removeValue(forKey: id)
        try persist(registrations)
    }

    private func persist(_ next: [String: RemotePushRegistration]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PiHome.write(JSONEncoder().encode(Array(next.values)), to: file, mode: 0o600)
    }

    private func cancel(_ id: String) {
        for (key, delivery) in deliveries where delivery.registrationID == id {
            delivery.cancel()
            deliveries.removeValue(forKey: key)
        }
    }

    func stop() {
        for delivery in deliveries.values { delivery.cancel() }
        deliveries.removeAll()
    }

    func send(agentID: AgentID, kind: Kind) {
        guard !registrations.isEmpty else { return }
        let now = now()
        if now.timeIntervalSince(window) >= 60 { window = now; eventCount = 0 }
        guard eventCount < 30 else { return }
        eventCount += 1
        guard let body = try? JSONEncoder().encode(Event(agentID: agentID, kind: kind)) else { return }
        // No pending queue: overload drops deliveries rather than growing memory or replaying later.
        for registration in registrations.values where deliveries.count < 16 {
            let id = UUID()
            var request = URLRequest(url: URL(string: "https://api.useshepherd.app/api/push/registrations/\(registration.id)/events")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue("Bearer \(registration.sendToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            let cancel = transport(request) { [weak self] status in
                guard let self else { return }
                self.queue.async {
                    self.deliveries.removeValue(forKey: id)
                    guard status == 401 || status == 410,
                          self.registrations[registration.id] == registration else { return }
                    // A revoked relay credential must not permanently consume a host slot.
                    // Never remove a replacement credential because an old request finished late.
                    try? self.unregister(registration.id)
                }
            }
            deliveries[id] = Delivery(registrationID: registration.id, cancel: cancel)
            queue.asyncAfter(deadline: .now() + .seconds(10)) { [weak self] in
                self?.deliveries.removeValue(forKey: id)?.cancel()
            }
        }
    }

    enum Failure: Error { case invalid, full }
}

final class PushHTTP: NSObject, URLSessionTaskDelegate {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: PushHTTP(), delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
