import Foundation
import ShepherdRemote
#if SHEPHERD_SENTRY
import Sentry
#endif

/// Sentry on the iOS client (docs/diagnostics.md): crashes, hangs, watchdog kills, MetricKit,
/// performance traces, profiles, and a masked replay around each error. On unless Settings ▸
/// Diagnostics turns it off. Only a build given a DSN reports (TestFlight, from the
/// `SHEPHERD_IOS_SENTRY_DSN` repository variable); local and simulator builds have none. The
/// simulator fixtures (Tests/ShepherdIOSChecks) compile without Sentry: only the app target sets
/// `SHEPHERD_SENTRY`.
enum MobileDiagnostics {
    static let shareKey = "shepherd.diagnostics.share"

    static var configured: Bool { dsn != nil }

    private static let dsn: String? = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "ShepherdSentryDSN") as? String,
              let url = URL(string: value), url.scheme == "https",
              url.host?.hasSuffix(".sentry.io") == true else { return nil }
        return value
    }()

    private static var cache: URL { URL.cachesDirectory.appending(path: "diagnostics", directoryHint: .isDirectory) }

    @MainActor static func start(defaults: UserDefaults = .standard) {
        guard let dsn, defaults.object(forKey: shareKey) as? Bool ?? true else { return }
        #if SHEPHERD_SENTRY
        let budget = DiagnosticsBudget(store: defaults)
        SentrySDK.start { options in
            options.dsn = dsn
            options.cacheDirectoryPath = cache.path
            // No IP, user or request headers (the push relay's bearer token rides in one).
            options.sendDefaultPii = false
            // Every trace: app start, screens, taps, network, file I/O, frames, time to display.
            options.tracesSampleRate = 1
            options.enableTimeToFullDisplayTracing = true
            // ponytail: a quarter of sessions profile while a trace runs, every app start does;
            // raise it if Sentry's profile hours allow.
            options.configureProfiling = {
                $0.lifecycle = .trace
                $0.sessionSampleRate = 0.25
                $0.profileAppStarts = true
            }
            options.enableMetricKit = true
            // The view tree (types, frames, identifiers; no text) rides with each error. No
            // screenshot: it would show prompts and code unmasked.
            options.attachViewHierarchy = true
            // Replays only the moments around an error, with every text and image masked.
            options.sessionReplay.sessionSampleRate = 0
            options.sessionReplay.onErrorSampleRate = 1
            options.beforeSend = { event in
                budget.take(event is Transaction ? .transaction : .error) ? event : nil
            }
        }
        #endif
    }

    /// Turning it off takes effect at once: capture stops and unsent reports are deleted.
    /// Turning it back on waits for the next launch: the SDK must not restart in-process.
    @MainActor static func stop() {
        #if SHEPHERD_SENTRY
        SentrySDK.close()
        #endif
        try? FileManager.default.removeItem(at: cache)
    }
}
