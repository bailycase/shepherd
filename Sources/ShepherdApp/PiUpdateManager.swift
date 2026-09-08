import Foundation
import SwiftUI

/// Checks the installed pi version and optionally updates pi plus its user
/// extensions. Checks are intentionally independent of the auto-update toggle
/// so the workspace can still warn when automatic updates are disabled.
@MainActor
final class PiUpdateManager: ObservableObject {
    static let shared = PiUpdateManager()

    static let packageName = "@earendil-works/pi-coding-agent"
    static let checkInterval: Duration = .seconds(86_400)

    @Published private(set) var currentVersion: String?
    @Published private(set) var latestVersion: String?
    enum UpdateTarget {
        case pi, extensions, both
    }

    @Published private(set) var isOutdated = false
    @Published private(set) var isChecking = false
    @Published private(set) var activeUpdate: UpdateTarget?
    @Published private(set) var extensionsUpdatedAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var lastChecked: Date?

    var isUpdating: Bool { activeUpdate != nil }
    var isBusy: Bool { isChecking || isUpdating }
    var canUpdatePi: Bool {
        Self.canUpdatePi(lastChecked: lastChecked, isOutdated: isOutdated, isBusy: isBusy)
    }
    var canUpdateExtensions: Bool { !isBusy && extensionsUpdatedAt == nil }

    static func canUpdatePi(lastChecked: Date?, isOutdated: Bool, isBusy: Bool) -> Bool {
        !isBusy && (lastChecked == nil || isOutdated)
    }

    private var timerTask: Task<Void, Never>?

    init() {}

    deinit {
        timerTask?.cancel()
    }

    func start() {
        guard timerTask == nil else { return }
        checkNow(applyAutomaticUpdates: true)
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.checkInterval)
                guard !Task.isCancelled else { return }
                self?.checkNow(applyAutomaticUpdates: true)
            }
        }
    }

    /// Called after either Settings toggle changes. Checks continue while
    /// both are off, but only enabled update commands run automatically.
    func applyAutoUpdateSetting() {
        let settings = AppSettings.shared
        guard settings.autoUpdatePi || settings.autoUpdateExtensions else { return }
        checkNow(applyAutomaticUpdates: true)
    }

    func checkNow(applyAutomaticUpdates: Bool = false) {
        guard !isBusy else { return }
        isChecking = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Self.checkVersions()
                currentVersion = result.current
                latestVersion = result.latest
                isOutdated = Self.isVersion(result.current, olderThan: result.latest)
                lastChecked = Date()
                lastError = nil
                let settings = AppSettings.shared
                let arguments = Self.automaticUpdateArguments(
                    updatePi: settings.autoUpdatePi,
                    updateExtensions: settings.autoUpdateExtensions
                )
                isChecking = false
                if applyAutomaticUpdates, !arguments.isEmpty {
                    runUpdates(arguments, target: Self.target(for: arguments))
                }
            } catch {
                lastError = error.localizedDescription
                lastChecked = Date()
                isChecking = false
            }
        }
    }

    func updatePiNow() {
        runUpdates([["update"]], target: .pi)
    }

    func updateExtensionsNow() {
        runUpdates([["update", "--extensions"]], target: .extensions)
    }

    static func automaticUpdateArguments(
        updatePi: Bool,
        updateExtensions: Bool
    ) -> [[String]] {
        var commands: [[String]] = []
        if updatePi { commands.append(["update"]) }
        if updateExtensions { commands.append(["update", "--extensions"]) }
        return commands
    }

    private static func target(for commands: [[String]]) -> UpdateTarget {
        commands.count > 1 ? .both : commands[0].contains("--extensions") ? .extensions : .pi
    }

    private func runUpdates(_ commands: [[String]], target: UpdateTarget) {
        guard !isBusy, !commands.isEmpty else { return }
        activeUpdate = target
        lastError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                for arguments in commands {
                    _ = try await Self.runPiCommand(arguments, discardOutput: true)
                    if !arguments.contains("--extensions") {
                        // Publish the installed version as soon as Pi finishes.
                        // The npm latest-version request below may take longer.
                        currentVersion = try await Self.readCurrentVersion()
                        if let latestVersion {
                            isOutdated = Self.isVersion(currentVersion ?? "", olderThan: latestVersion)
                        }
                    } else {
                        extensionsUpdatedAt = Date()
                    }
                }
                let result = try await Self.checkVersions()
                currentVersion = result.current
                latestVersion = result.latest
                isOutdated = Self.isVersion(result.current, olderThan: result.latest)
                lastChecked = Date()
            } catch {
                lastError = error.localizedDescription
            }
            activeUpdate = nil
        }
    }

    static func isVersion(_ current: String, olderThan latest: String) -> Bool {
        let left = versionComponents(current)
        let right = versionComponents(latest)
        guard !left.isEmpty, !right.isEmpty else { return false }
        for index in 0..<max(left.count, right.count) {
            let lhs = index < left.count ? left[index] : 0
            let rhs = index < right.count ? right[index] : 0
            if lhs != rhs { return lhs < rhs }
        }
        return false
    }

    private static func versionComponents(_ version: String) -> [Int] {
        version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "+" })
            .prefix(3)
            .compactMap { Int($0) }
    }

    private struct VersionResult: Sendable {
        let current: String
        let latest: String
    }

    private enum CommandError: LocalizedError {
        case launch(String)
        case failed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .launch(let message): return message
            case .failed(let message): return message
            case .timedOut: return "pi update check timed out"
            }
        }
    }

    private static func readCurrentVersion() async throws -> String {
        let current = try await runPiCommand(["--version"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else {
            throw CommandError.failed("could not determine pi version")
        }
        return current
    }

    private static func checkVersions() async throws -> VersionResult {
        async let currentOutput = readCurrentVersion()
        async let latestOutput = runCommand(
            executable: "/bin/zsh",
            arguments: ["-l", "-c", "exec npm view \(shellQuote(packageName)) version --json"]
        )
        let current = try await currentOutput
        let latest = try await latestOutput.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !current.isEmpty, !latest.isEmpty else {
            throw CommandError.failed("could not determine pi version")
        }
        return VersionResult(current: current, latest: latest)
    }

    private struct CommandOutput: Sendable {
        let stdout: String
    }

    private final class CommandState: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return false }
            finished = true
            return true
        }

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }
    }

    private static func runPiCommand(_ arguments: [String], discardOutput: Bool = false) async throws -> CommandOutput {
        let redirection = discardOutput ? " >/dev/null 2>&1" : ""
        return try await runCommand(
            executable: "/bin/zsh",
            arguments: ["-l", "-c", "exec pi \(arguments.map(shellQuote).joined(separator: " "))\(redirection)"]
        )
    }

    private static func shellQuote(_ argument: String) -> String {
        "'\(argument.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Process work runs off the main actor. A timeout terminates the child so
    /// a network outage cannot leave a detached updater alive indefinitely.
    private static func runCommand(executable: String, arguments: [String]) async throws -> CommandOutput {
        try await Task.detached {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let output = Pipe()
                let errorOutput = Pipe()
                process.standardOutput = output
                process.standardError = errorOutput
                let state = CommandState()

                @Sendable func finish(_ result: Result<CommandOutput, Error>) {
                    guard state.claim() else { return }
                    continuation.resume(with: result)
                }

                process.terminationHandler = { process in
                    let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    let stderr = String(decoding: errorOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    if process.terminationStatus == 0 {
                        finish(.success(CommandOutput(stdout: stdout)))
                    } else {
                        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        finish(.failure(CommandError.failed(message.isEmpty ? "pi command failed" : message)))
                    }
                }

                do {
                    try process.run()
                } catch {
                    finish(.failure(CommandError.launch(error.localizedDescription)))
                    return
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                    if !state.isFinished {
                        process.terminate()
                        finish(.failure(CommandError.timedOut))
                    }
                }
            }
        }.value
    }
}
