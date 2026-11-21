import Foundation

// A version of Vite, for example 8.3.8 or 9.0.0-beta.1. A prerelease is lower than its release.
public struct ViteVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let isPrerelease: Bool

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutBuild = trimmed.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parts = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = (parts.first ?? "").split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }

        guard numbers.count == 3, let major = numbers[0], let minor = numbers[1], let patch = numbers[2] else {
            return nil
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.isPrerelease = parts.count == 2
    }

    public var description: String {
        isPrerelease ? "\(major).\(minor).\(patch)-prerelease" : "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: ViteVersion, rhs: ViteVersion) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }

        return lhs.isPrerelease && !rhs.isPrerelease
    }
}

// The Vite versions that Live accepts (owner, 2026-11-17). Each fix holds the fix for
// GHSA-p4f5-76q4-ffq7 and the older fixes of research 7. A later patch of a fixed minor line passes.
// A minor line above the last fixed line of its major passes. Vite 9 and later pass. Vite 5, older
// versions and the line 8.0 have no fix.
public enum ViteLiveCheck {
    public static let fixes = ["6.4.6", "7.3.8", "8.1.7", "8.2.5", "8.3.7"].compactMap(ViteVersion.init)

    // The text of the approved list for a version without a fix in its own major.
    static let approvedFixes = "6.4.6, 7.3.8, 8.1.7"

    public static func allowsLive(_ version: ViteVersion) -> Bool {
        guard version.major < 9 else {
            return true
        }

        let line = fixes.filter { $0.major == version.major }

        guard let last = line.max() else {
            return false
        }

        if let fix = line.first(where: { $0.minor == version.minor }) {
            return version >= fix
        }

        return version.minor > last.minor
    }

    // A version that nexusd cannot read counts as an old version (owner, 4e question 7).
    public static func allowsLive(installed text: String?) -> Bool {
        text.flatMap(ViteVersion.init).map(allowsLive) ?? false
    }

    // The first fix above version in its own major, for example 8.3.7 for 8.3.5 and 8.1.7 for
    // 8.0.3. nil for Vite 5 and older.
    public static func fix(for version: ViteVersion) -> ViteVersion? {
        fixes.filter { $0.major == version.major && $0 > version }.min()
    }

    // The version in node_modules/vite/package.json of folder or of a parent folder up to the root
    // of git. pnpm keeps a package that is no direct dependency in node_modules/.pnpm/node_modules.
    // A folder without git counts alone, as for the lock file of NodeProject.
    public static func installedVersion(in folder: URL) -> String? {
        let start = RealPath.of(folder)
        let top = ProjectFolder.gitRoot(from: start) ?? start
        var current = start

        while true {
            for file in ["node_modules/vite/package.json", "node_modules/.pnpm/node_modules/vite/package.json"] {
                if let version = version(inPackageFile: (current as NSString).appendingPathComponent(file)) {
                    return version
                }
            }

            guard current != top, current != "/" else {
                return nil
            }

            current = (current as NSString).deletingLastPathComponent
        }
    }

    // The texts of an old or unknown version (ux-texts.md and contract 4e, "Texts").
    // install is the install command of the project, for example npm install.
    public static func liveBlockedText(version: String?, install: String) -> String {
        guard let version, let parsed = ViteVersion(version) else {
            return "Live is not possible for this site. Nexus cannot find the version of Vite in node_modules. Vite is the dev server of the styles and scripts. Run \(install) in this project to use Live."
        }

        return "Live is not possible for this site. It has Vite \(version), which lets visitors read files on your Mac. Update Vite in this project to \(updateTarget(for: parsed)) or later to use Live."
    }

    public static func appRefusal(version: String?, install: String) -> String {
        guard let version, let parsed = ViteVersion(version) else {
            return "Nexus cannot share this app. Its dev server is Vite, but Nexus cannot find the version of Vite in node_modules. Run \(install) in this project. Then share the app again."
        }

        return "Nexus cannot share this app. Its dev server is Vite \(version), which lets visitors read files on your Mac. Update Vite in this project to \(updateTarget(for: parsed)) or later. Then share the app again."
    }

    // The text of an old version names the fix of the line of the project (owner, 4e question 1).
    // Vite 5 and older keep the approved list.
    private static func updateTarget(for version: ViteVersion) -> String {
        fix(for: version).map(\.description) ?? approvedFixes
    }

    private static func version(inPackageFile path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return package["version"] as? String
    }
}
