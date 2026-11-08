import Foundation
import NexusCore
import Sentry

// Crash reports of the app and of nexusd (owner, 2026-11-07). The SDK of Sentry writes a crash to
// disk and sends it at the next start. Only crashes: no other errors, no hangs, no sessions, no
// performance data and no breadcrumbs. A failed program keeps "Send report". The organization in
// Sentry stores no IP address and no location. Before a report goes, the name of the home folder
// and the account name leave each text. The setting is in the defaults of the app, and nexusd reads
// the same defaults.
public enum CrashReports {
    public static let dsn = "https://4455756da7312c659e52d6e870f8b6a9@o4512390385893376.ingest.de.sentry.io/4512390391857232"

    public static let setting = "sendsCrashReports"

    // A debug build sends crashes only with this setting on, for a check of the reports.
    public static let debugSetting = "sendsDebugCrashReports"

    // nexusd is in Contents/MacOS of the app, so its main bundle is the app and its standard
    // defaults are the defaults of the app.
    public static var defaults: UserDefaults {
        Bundle.main.bundleIdentifier == NexusIdentifiers.app ? .standard : UserDefaults(suiteName: NexusIdentifiers.app) ?? .standard
    }

    public static var isOn: Bool {
        defaults.object(forKey: setting) as? Bool ?? true
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    // process is "app" or "nexusd". A second call with the setting off stops the SDK. The request
    // of the app gives nexusd the new value, because the defaults of another process can reach
    // nexusd a moment later.
    public static func apply(process: String, isOn: Bool = CrashReports.isOn) {
        guard isOn, !isDebugBuild || defaults.bool(forKey: debugSetting) else {
            if SentrySDK.isEnabled {
                SentrySDK.close()
            }

            return
        }

        guard !SentrySDK.isEnabled else {
            return
        }

        SentrySDK.start { options in
            options.dsn = dsn
            // nexusd has the app as its main bundle, so without its own folder both processes
            // would share one file of the crash state.
            options.cacheDirectoryPath = cacheFolder(of: process)
            options.releaseName = "nexus@\(NexusVersion.current())+\(NexusVersion.build())"
            options.environment = isDebugBuild ? "development" : "production"
            options.sendDefaultPii = false
            options.enableCrashHandler = true
            options.enableAutoSessionTracking = false
            options.enableAppHangTracking = false
            options.enableWatchdogTerminationTracking = false
            options.enableMetricKit = false
            options.enableAutoPerformanceTracing = false
            options.enableNetworkTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableCaptureFailedRequests = false
            options.enableAutoBreadcrumbTracking = false
            options.enableFileIOTracing = false
            options.enableCoreDataTracing = false
            options.enableSwizzling = false
            options.enableLogs = false
            options.enableMetrics = false
            options.sendClientReports = false
            options.maxBreadcrumbs = 0
            options.tracesSampleRate = nil
            options.initialScope = { scope in
                scope.setTag(value: process, key: "process")
                return scope
            }
            options.beforeSend = { event in
                anonymized(event)
            }
        }
    }

    static func cacheFolder(of process: String) -> String {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(filePath: NSTemporaryDirectory())
        return caches.appending(path: "\(NexusIdentifiers.app)/crash-reports/\(process)", directoryHint: .isDirectory).path(percentEncoded: false)
    }

    // A report holds the place of the crash, the versions of Nexus and macOS, and no names of the
    // user, the Mac or the home folder.
    static func anonymized(_ event: Event) -> Event {
        event.serverName = nil
        event.user = nil
        event.breadcrumbs = nil
        event.request = nil
        event.extra = nil

        if let formatted = event.message?.formatted {
            event.message = SentryMessage(formatted: anonymized(formatted))
        }

        for exception in event.exceptions ?? [] {
            exception.value = exception.value.map(anonymized)
            exception.mechanism?.desc = exception.mechanism?.desc.map(anonymized)
            anonymize(exception.stacktrace)
        }

        for thread in event.threads ?? [] {
            thread.name = thread.name.map(anonymized)
            anonymize(thread.stacktrace)
        }

        anonymize(event.stacktrace)

        for image in event.debugMeta ?? [] {
            image.codeFile = image.codeFile.map(anonymized)
        }

        event.tags = event.tags?.mapValues(anonymized)
        event.context = event.context?.mapValues { values in
            anonymizedValues(values.filter { !removedContextKeys.contains($0.key) })
        }

        return event
    }

    // The name of the Mac, a hash that stays the same for each Mac, and the locale, which shows the
    // region of the user.
    static let removedContextKeys: Set<String> = ["name", "device_app_hash", "locale"]

    private static func anonymize(_ stacktrace: SentryStacktrace?) {
        for frame in stacktrace?.frames ?? [] {
            frame.fileName = frame.fileName.map(anonymized)
            frame.package = frame.package.map(anonymized)
            frame.module = frame.module.map(anonymized)
            frame.function = frame.function.map(anonymized)
        }
    }

    private static func anonymizedValues(_ values: [String: Any]) -> [String: Any] {
        values.mapValues { value in
            switch value {
            case let text as String: anonymized(text)
            case let nested as [String: Any]: anonymizedValues(nested)
            case let list as [Any]: list.map { ($0 as? String).map(anonymized) ?? $0 }
            default: value
            }
        }
    }

    static func anonymized(_ text: String) -> String {
        anonymized(text, home: NSHomeDirectory())
    }

    // Only the path of the home folder goes. The account name alone can also be a part of a bundle
    // id or of a word in the code.
    static func anonymized(_ text: String, home: String) -> String {
        home.count > 1 ? text.replacingOccurrences(of: home, with: "~") : text
    }
}
