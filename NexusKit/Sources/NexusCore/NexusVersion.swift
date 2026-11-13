import Foundation

public enum NexusVersion {
    public static func current(in bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    public static func build(in bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    // The build that the restart of nexusd after an update compares. Each Debug build has build 1.
    // So a Debug build adds the time of its nexusd file, which each Xcode build writes again.
    // Without it the old nexusd keeps running. macOS then refuses it the key of the root
    // certificate, because its file changed. A release keeps the build only. An update writes its
    // files one after the other. A half-written app must not look like a new build.
    public static func identity() -> String {
        #if DEBUG
        fileTime(ofAppAt: Bundle.main.bundleURL).map { "\(build())+\($0)" } ?? build()
        #else
        build()
        #endif
    }

    // A Debug app without its nexusd file is in the middle of an Xcode build. So it has no new
    // build yet.
    public static func identityOnDisk(ofAppAt app: URL) -> String? {
        #if DEBUG
        guard let build = buildOnDisk(ofAppAt: app), let time = fileTime(ofAppAt: app) else {
            return nil
        }

        return "\(build)+\(time)"
        #else
        buildOnDisk(ofAppAt: app)
        #endif
    }

    // Bundle keeps the Info.plist that it read first. An update replaces the file on disk, so this
    // reads the file again each time. nil when the app is not there, for example during an update.
    private static func buildOnDisk(ofAppAt app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appending(path: "Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }

        return plist["CFBundleVersion"] as? String
    }

    private static func fileTime(ofAppAt app: URL) -> Int? {
        let daemon = app.appending(path: "Contents/MacOS/nexusd").path(percentEncoded: false)
        let changed = (try? FileManager.default.attributesOfItem(atPath: daemon))?[.modificationDate] as? Date
        return changed.map { Int($0.timeIntervalSince1970) }
    }
}
