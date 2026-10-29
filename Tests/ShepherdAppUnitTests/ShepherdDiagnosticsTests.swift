import Foundation
import Sentry
import ShepherdTestKit
import Testing
@testable import ShepherdApp

@Suite("Shepherd diagnostics")
struct ShepherdDiagnosticsTests {
    @Test @MainActor func consentDefaultsOffPersistsAndResetRevokesIt() {
        let defaults = ScratchDefaults()
        let settings = AppSettings(store: defaults)
        var changes: [Bool] = []
        settings.onDiagnosticsChange = { changes.append($0) }
        #expect(!settings.shareDiagnostics)
        settings.shareDiagnostics = true
        settings.shareDiagnostics = true
        #expect(AppSettings(store: defaults).shareDiagnostics)
        settings.resetToDefaults()
        #expect(!AppSettings(store: defaults).shareDiagnostics)
        #expect(changes == [true, false])
    }

    @Test func consentAndTheDailyCapSurviveRestartsAndReenabling() {
        let defaults = ScratchDefaults()
        let gate = DiagnosticsGate(store: defaults)
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        #expect(!gate.accept(now: now))
        gate.setEnabled(true)
        for _ in 0..<DiagnosticsGate.dailyLimit { #expect(gate.accept(now: now)) }
        #expect(!gate.accept(now: now))
        gate.setEnabled(false)
        #expect(!gate.accept(now: now.addingTimeInterval(86_400)))
        let restarted = DiagnosticsGate(store: defaults)
        restarted.setEnabled(true)
        #expect(!restarted.accept(now: now))
        #expect(restarted.accept(now: now.addingTimeInterval(86_400)))
    }

    @Test func onlyConfiguredHostedHTTPSProjectsAreAccepted() {
        let valid = "https://publickey@o123.ingest.us.sentry.io/456"
        #expect(ShepherdDiagnostics.dsn(valid) == valid)
        for invalid in [nil, "", "$(SHEPHERD_SENTRY_DSN)", "http://key@o1.ingest.sentry.io/1",
                        "https://key:secret@o1.ingest.sentry.io/1", "https://key@example.com/1",
                        "https://key@o1.ingest.sentry.io/1?token=secret", "https://o1.ingest.sentry.io/1"] as [String?] {
            #expect(ShepherdDiagnostics.dsn(invalid) == nil)
        }
    }

    @Test(arguments: [("MXCPUException", "mx_cpu_exception"), ("MXDiskWriteException", "mx_disk_write_exception"),
                      ("MXHangDiagnostic", "mx_hang_diagnostic")])
    func systemPerformanceDiagnosticsRetainTheirKindButNotRawPayload(_ type: String, _ mechanism: String) {
        let event = Event(level: .error)
        let exception = Exception(value: "PRIVATE_DIAGNOSTIC_SENTINEL", type: type)
        exception.mechanism = Mechanism(type: mechanism)
        event.exceptions = [exception]
        let clean = ShepherdDiagnostics.sanitized(event)
        #expect(clean.exceptions?.first?.type == type)
        #expect(clean.exceptions?.first?.mechanism?.type == mechanism)
        #expect(clean.exceptions?.first?.value == nil)
    }

    @Test func theSDKOnlyCollectsExplicitPerformanceAndCrashDiagnostics() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let options = ShepherdDiagnostics.makeOptions(dsn: "https://key@o1.ingest.sentry.io/1",
                                                       cache: URL(fileURLWithPath: "/unused"), session: session)
        #expect(options.maxCacheItems == 10 && options.maxBreadcrumbs == 32)
        #expect(!options.sendDefaultPii && !options.enableMemoryIntrospection)
        #expect(!options.enableAutoBreadcrumbTracking && !options.enableNetworkBreadcrumbs)
        #expect(options.enableAutoSessionTracking && !options.enableCaptureFailedRequests)
        #expect(options.enableMetricKit && !options.enableMetricKitRawPayload)
        #expect(options.enableLogs && options.enableMetrics)
        #expect(options.beforeSendLog?(SentryLog(level: .info, body: "app.started")) == nil,
                "options fail closed until the owned emission callbacks are installed")
        #expect(!options.enableAutoPerformanceTracing && options.tracesSampleRate == 1)
        #expect(!options.enableNetworkTracking && !options.enableFileIOTracing && !options.enableCoreDataTracing)
        #expect(options.enableAppHangTracking && options.appHangTimeoutInterval == 5)
        #expect(options.enableCrashHandler && options.enableUncaughtNSExceptionReporting)
        #expect(options.swiftAsyncStacktraces)
        #expect(options.urlSession === session)
    }

    @Test(arguments: [false, true])
    func profilingIsManualAndNeverStartsFromPersistedLaunchConfiguration(_ enabled: Bool) {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let options = ShepherdDiagnostics.makeOptions(dsn: "https://key@o1.ingest.sentry.io/1",
            cache: URL(fileURLWithPath: "/unused"), session: session, profilingEnabled: enabled)
        let profile = SentryProfileOptions()
        options.configureProfiling?(profile)
        #expect(profile.lifecycle == .manual)
        #expect(profile.sessionSampleRate == (enabled ? 1 : 0))
        #expect(!profile.profileAppStarts)
    }

    @Test func performanceLogAndMetricBudgetsAreSeparatePersistedAndRevoked() {
        let defaults = ScratchDefaults()
        let gate = DiagnosticsGate(store: defaults)
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        gate.setEnabled(true)
        for kind in DiagnosticsGate.Kind.allCases where kind != .duration {
            for _ in 0..<kind.limit { #expect(gate.accept(kind: kind, now: now)) }
            #expect(!gate.accept(kind: kind, now: now))
        }
        let restarted = DiagnosticsGate(store: defaults)
        restarted.setEnabled(true)
        for kind in DiagnosticsGate.Kind.allCases where kind != .duration {
            #expect(!restarted.accept(kind: kind, now: now))
            #expect(restarted.accept(kind: kind, now: now.addingTimeInterval(86_400)))
        }
        restarted.setEnabled(false)
        #expect(!restarted.isEnabled)
        for kind in DiagnosticsGate.Kind.allCases { #expect(!restarted.accept(kind: kind, now: now.addingTimeInterval(86_400))) }
    }

    @Test func durationBudgetsSpreadAcrossHoursOperationsAndRestarts() {
        let defaults = ScratchDefaults()
        let gate = DiagnosticsGate(store: defaults)
        gate.setEnabled(true)
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        let operations = Array(ShepherdDiagnostics.operations.sorted().prefix(5))
        for operation in operations {
            #expect(gate.accept(kind: .duration, now: now, operation: operation))
            #expect(gate.accept(kind: .duration, now: now, operation: operation))
            #expect(!gate.accept(kind: .duration, now: now, operation: operation))
        }
        #expect(!gate.accept(kind: .duration, now: now, operation: "tool.other"))
        let restarted = DiagnosticsGate(store: defaults)
        restarted.setEnabled(true)
        #expect(!restarted.accept(kind: .duration, now: now, operation: operations[0]))
        #expect(restarted.accept(kind: .duration, now: now.addingTimeInterval(3600), operation: operations[0]))
        #expect(!restarted.accept(kind: .duration, now: now.addingTimeInterval(3600), operation: "PRIVATE_SENTINEL"))
        defaults.set(DiagnosticsGate.Kind.duration.limit, forKey: "shepherd.diagnostics.duration.count")
        #expect(!restarted.accept(kind: .duration, now: now.addingTimeInterval(7200), operation: operations[0]))
        #expect(restarted.accept(kind: .duration, now: now.addingTimeInterval(86_400), operation: operations[0]))
    }

    @Test func samplingStopsAtBothItsCountAndElapsedTimeBounds() {
        var budget = DiagnosticsSamplingBudget(startedAt: 100)
        for _ in 0..<DiagnosticsSamplingBudget.limit {
            let accepted = budget.take(at: 100)
            #expect(accepted)
        }
        let overCount = budget.take(at: 100)
        #expect(!overCount)
        var expired = DiagnosticsSamplingBudget(startedAt: 100)
        for (uptime, expected) in [(99.0, false), (.infinity, false), (86_499, true), (86_500, false)] {
            let accepted = expired.take(at: uptime)
            #expect(accepted == expected)
        }
    }

    @Test func resourcesOnlyRetainBoundedNumericAllowlistedSamples() throws {
        let source = Event(level: .error)
        source.context = ["shepherd.resources": ["samples": (0..<20).map { index in
            ["app.rss_bytes": Double(index), "PRIVATE_SENTINEL": 12, "pi.count": -1, "pi.rss_bytes": Double.infinity]
        }]]
        let clean = ShepherdDiagnostics.sanitized(source)
        let samples = try #require(clean.context?["shepherd.resources"]?["samples"] as? [[String: Double]])
        #expect(samples.count == 10)
        #expect(samples.first == ["app.rss_bytes": 10])
        #expect(samples.last == ["app.rss_bytes": 19])
        let encoded = try JSONSerialization.data(withJSONObject: clean.serialize())
        #expect(!String(decoding: encoded, as: UTF8.self).contains("PRIVATE_SENTINEL"))
    }

    @Test func deepStacksKeepTheCrashingFramesAndCrashingThreads() {
        let frames = (0..<300).map { index in
            let frame = Frame()
            frame.instructionAddress = String(index)
            return frame
        }
        let source = Event(level: .fatal)
        source.stacktrace = SentryStacktrace(frames: frames, registers: [:])
        source.threads = (0..<150).map { index in
            let thread = SentryThread(threadId: NSNumber(value: index))
            thread.crashed = NSNumber(value: index == 149)
            return thread
        }
        let clean = ShepherdDiagnostics.sanitized(source)
        #expect(clean.stacktrace?.frames.count == 256)
        #expect(clean.stacktrace?.frames.last?.instructionAddress == "299")
        #expect(clean.threads?.count == 128)
        #expect(clean.threads?.first?.threadId == 149)
    }

    @Test(arguments: [
        ("SWIFT TASK CONTINUATION MISUSE: PRIVATE_SECRET", "continuationMisuse"),
        ("Fatal error: Duplicate values for key: PRIVATE_SECRET", "duplicateKey"),
        ("Fatal error: Index out of range PRIVATE_SECRET", "indexOutOfRange"),
        ("Unexpectedly found nil while unwrapping an Optional value PRIVATE_SECRET", "unexpectedNil"),
        ("Shepherd's resource bundle has no Extensions/PRIVATE_SECRET", "missingEmbeddedResource"),
        ("Precondition failed: PRIVATE_SECRET", "precondition"),
        ("Fatal error: Range requires lowerBound <= upperBound PRIVATE_SECRET", "rangeBounds"),
        ("Fatal error: Not enough bits to represent the passed value PRIVATE_SECRET", "integerConversion"),
        ("Fatal error: Incorrect actor executor assumption; PRIVATE_SECRET", "actorIsolation"),
        ("Fatal error: makeEmpty closure must be configured for CircularList PRIVATE_SECRET", "terminalBuffer"),
        ("Fatal error: Handled above PRIVATE_SECRET", "unreachableRequest"),
        ("Fatal error: PRIVATE_SECRET", "fatalError"),
        ("PRIVATE_SECRET", "")
    ])
    func assertionEvidenceKeepsOnlyFixedCategories(reason: String, category: String) throws {
        let source = Event(level: .fatal)
        source.exceptions = [Exception(value: reason, type: "EXC_BREAKPOINT")]
        source.tags = ["crash.assertion": "PRIVATE_SECRET"]
        let clean = ShepherdDiagnostics.sanitized(source)
        #expect(clean.tags?["crash.assertion"] == (category.isEmpty ? nil : category))
        #expect(clean.exceptions?.first?.value == nil)
        #expect(clean.tags?["crash.reason"] == (category.isEmpty ? "unclassified" : "classified"))
        #expect(clean.tags?["crash.stack"] == "missing")
        let json = try JSONSerialization.data(withJSONObject: clean.serialize())
        #expect(!String(decoding: json, as: UTF8.self).contains("PRIVATE_SECRET"))
        #expect(ShepherdDiagnostics.sanitized(clean).tags?["crash.assertion"] == clean.tags?["crash.assertion"])
    }

    @Test(arguments: [0, 1, 3, 257])
    func crashSanitizationLabelsCapturedEvidenceAndRetainsTheFaultingFrames(count: Int) {
        let frames = (0..<count).map { index in
            let frame = Frame()
            frame.instructionAddress = "0x\(index)"
            frame.function = "frame\(index)"
            return frame
        }
        let source = Event(level: .fatal)
        let exception = Exception(value: "PRIVATE_SECRET", type: "EXC_BREAKPOINT")
        exception.stacktrace = SentryStacktrace(frames: frames, registers: [:])
        source.exceptions = [exception]
        let clean = ShepherdDiagnostics.sanitized(source)
        #expect(clean.exceptions?.first?.stacktrace?.frames.map(\.instructionAddress) == frames.suffix(256).map(\.instructionAddress))
        #expect(clean.exceptions?.first?.stacktrace?.frames.map(\.function) == frames.suffix(256).map(\.function))
        #expect(clean.tags?["crash.stack"] == (count == 0 ? "missing" : count == 1 ? "singleFrame" : count > 256 ? "truncated" : "multipleFrames"))
        #expect(clean.tags?["crash.reason"] == "unclassified")
        source.exceptions?.first?.value = nil
        #expect(ShepherdDiagnostics.sanitized(source).tags?["crash.reason"] == "unavailable")
    }

    @Test func failureMetadataIsAllowlistedInEventsAndBreadcrumbs() {
        let source = Event(level: .error)
        source.tags = ["shepherd.failure": "agent.start_failed", "startup.kind": "engineMissing",
                       "startup.stage": "launch", "failure.category": "PRIVATE_SECRET", "tool.kind": "PRIVATE_TOOL"]
        let crumb = Breadcrumb(level: .info, category: "shepherd")
        crumb.message = "tool.failed"
        crumb.setData(value: "mcp", key: "tool.kind")
        crumb.setData(value: "other", key: "failure.category")
        crumb.setData(value: "PRIVATE_PATH", key: "startup.stage")
        source.breadcrumbs = [crumb]
        let clean = ShepherdDiagnostics.sanitized(source)
        #expect(clean.tags?["startup.kind"] == "engineMissing")
        #expect(clean.tags?["startup.stage"] == "launch")
        #expect(clean.tags?["failure.category"] == nil)
        #expect(clean.tags?["tool.kind"] == nil)
        #expect(clean.breadcrumbs?.first?.data?["tool.kind"] as? String == "mcp")
        #expect(clean.breadcrumbs?.first?.data?["failure.category"] as? String == "other")
        #expect(clean.breadcrumbs?.first?.data?["startup.stage"] == nil)
    }

    @Test func privateEventContentIsDroppedButCrashAddressesAndImageIDsSurvive() throws {
        let secret = "PRIVATE_PROMPT_API_KEY_PATH"
        let source = Event(level: .fatal)
        source.message = SentryMessage(formatted: secret)
        source.extra = ["prompt": secret]
        source.serverName = secret
        source.user = User(userId: secret)
        source.context = ["os": ["version": "26.0", "private": secret],
                          "device": ["model": "Mac14,2", "name": secret],
                          "app": ["app_name": secret]]
        source.tags = ["arbitrary": secret, "shepherd.installation": secret]
        let frame = Frame()
        frame.instructionAddress = "0x1234"
        frame.imageAddress = "0x1000"
        frame.function = "Shepherd.render"
        frame.package = "/Users/\(secret)/Shepherd"
        frame.vars = ["prompt": secret]
        frame.contextLine = secret
        let stack = SentryStacktrace(frames: [frame], registers: ["x0": secret])
        let exception = Exception(value: secret, type: "EXC_BAD_ACCESS")
        exception.stacktrace = stack
        let mechanism = Mechanism(type: "mach")
        mechanism.data = ["reason": secret]
        mechanism.desc = secret
        mechanism.handled = false
        exception.mechanism = mechanism
        source.exceptions = [exception, Exception(value: secret, type: secret)]
        let thread = SentryThread(threadId: 1)
        thread.name = secret
        thread.stacktrace = stack
        thread.crashed = true
        source.threads = [thread]
        let image = DebugMeta()
        image.debugID = "12345678-1234-1234-1234-123456789ABC"
        image.codeFile = "/Users/\(secret)/Shepherd"
        image.imageAddress = "0x1000"
        source.debugMeta = [image]
        let unsafe = Breadcrumb(level: .info, category: "http")
        unsafe.message = secret
        let safe = Breadcrumb(level: .info, category: "shepherd")
        safe.message = "process.exited"
        safe.setData(value: Int32(1), key: "exit_code")
        safe.setData(value: secret, key: "prompt")
        source.breadcrumbs = [unsafe, safe]

        let clean = ShepherdDiagnostics.sanitized(source)
        let json = try JSONSerialization.data(withJSONObject: clean.serialize())
        #expect(!String(decoding: json, as: UTF8.self).contains(secret))
        #expect(clean.exceptions?.first?.type == "EXC_BAD_ACCESS")
        #expect(clean.exceptions?.last?.type == "Native crash")
        #expect(clean.exceptions?.first?.stacktrace?.frames.first?.instructionAddress == "0x1234")
        #expect(clean.debugMeta?.first?.debugID == image.debugID)
        #expect(clean.debugMeta?.first?.codeFile == "Shepherd")
        #expect(clean.breadcrumbs?.count == 1)
        #expect(clean.breadcrumbs?.first?.data?["exit_code"] as? Int32 == 1)
        #expect(clean.context?["os"]?["version"] as? String == "26.0")
    }
}
