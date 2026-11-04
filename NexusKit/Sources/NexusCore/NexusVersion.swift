import Foundation

public enum NexusVersion {
    public static func current(in bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    public static func build(in bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    // Bundle keeps the Info.plist that it read first. An update replaces the file on disk, so this
    // reads the file again each time. nil when the app is not there, for example during an update.
    public static func buildOnDisk(ofAppAt app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appending(path: "Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }

        return plist["CFBundleVersion"] as? String
    }
}
