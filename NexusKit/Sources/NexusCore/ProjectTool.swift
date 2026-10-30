import Foundation

// The programs that nexus runs with the versions of the site in the current folder (D38).
public enum ProjectTool: String, Codable, Sendable, CaseIterable {
    case php
    case composer
    case node
    case npm
}

// The bin folder of Nexus has a link to the nexus command for nexus itself and for each tool. A
// link that is called php runs as nexus php. The PATH setting puts this folder first on the PATH
// (D39). A link to an app that moved or went away does not count as a command. So the shell then
// uses the next php on the PATH.
public enum CommandLinks {
    public static let names = ["nexus"] + ProjectTool.allCases.map(\.rawValue)

    // macOS can run a downloaded app from a temporary copy in an AppTranslocation folder. A link to
    // that copy breaks at the next start of the app.
    public static func canPoint(to command: URL) -> Bool {
        let path = command.path(percentEncoded: false)
        return FileManager.default.isExecutableFile(atPath: path) && !path.contains("/AppTranslocation/")
    }

    public static func write(in folder: URL, command: URL, using fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = command.path(percentEncoded: false)

        for name in names {
            let link = folder.appending(path: name).path(percentEncoded: false)

            if (try? fileManager.destinationOfSymbolicLink(atPath: link)) == target {
                continue
            }

            if (try? fileManager.attributesOfItem(atPath: link)) != nil {
                try fileManager.removeItem(atPath: link)
            }

            try fileManager.createSymbolicLink(atPath: link, withDestinationPath: target)
        }
    }
}
