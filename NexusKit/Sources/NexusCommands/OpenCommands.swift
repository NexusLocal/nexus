import ArgumentParser
import Foundation
import NexusCore
import NexusIPC

struct SiteTargetError: Error, CustomStringConvertible {
    let description: String
}

// The site or the workspace that nexus open, nexus edit and the database commands mean. A host
// names a site or a workspace. Without a host, the workspace of the current folder comes first,
// then its site.
struct SiteTarget: Equatable {
    let site: SiteInfo
    let workspace: WorkspaceInfo?

    static func find(host: String?, folder: String, in sites: [SiteInfo], example: String) throws -> SiteTarget {
        if let host {
            return try named(host, in: sites)
        }

        if let target = try? WorkspaceTarget.find(name: nil, site: nil, folder: folder, in: sites) {
            return SiteTarget(site: target.site, workspace: target.workspace)
        }

        guard let site = WorkspaceTarget.currentSite(folder: folder, in: sites) else {
            throw SiteTargetError(description: "\(folder) is in no site of Nexus. Give a host, for example: \(example)")
        }

        return SiteTarget(site: site, workspace: nil)
    }

    private static func named(_ host: String, in sites: [SiteInfo]) throws -> SiteTarget {
        if let site = sites.first(where: { $0.hosts.contains(host) }) {
            return SiteTarget(site: site, workspace: nil)
        }

        for site in sites {
            if let workspace = site.workspaces?.first(where: { $0.hosts?.contains(host) == true }) {
                return SiteTarget(site: site, workspace: workspace)
            }
        }

        throw SiteTargetError(description: "Nexus has no site or workspace \(host). See: nexus site list")
    }

    var siteHost: String {
        site.hosts.first ?? ""
    }

    var host: String {
        workspace.map { $0.hosts?.first ?? $0.name } ?? siteHost
    }

    var url: String? {
        guard let workspace else {
            return site.url
        }

        return workspace.url
    }

    var folder: String {
        workspace?.folder ?? site.folder
    }

    // A site on the public folder of a project opens the project in the editor.
    var projectFolder: String {
        ProjectFolder.projectFolder(ofSiteFolder: URL(filePath: folder, directoryHint: .isDirectory))
    }
}

// The code editor of nexus edit, as the app chooses it in Settings > General. A chosen app that
// is not installed anymore gives the first known editor, as in the app.
enum EditorChoice: Equatable {
    case none
    case app(path: String)
    case firstKnown

    init(preference: String?, appExists: (String) -> Bool) {
        guard let preference else {
            self = .firstKnown
            return
        }

        if preference.isEmpty {
            self = .none
            return
        }

        self = appExists(preference) ? .app(path: preference) : .firstKnown
    }

    static var current: EditorChoice {
        let preference = UserDefaults.standard.persistentDomain(forName: NexusIdentifiers.app)?[CodeEditors.preferenceKey] as? String

        return EditorChoice(preference: preference) { FileManager.default.fileExists(atPath: $0) }
    }
}

struct OpenSite: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Opens the site or the workspace of the current folder in the browser, for example: nexus open",
        discussion: "Give a host to open another site or workspace, for example: nexus open shop.test"
    )

    @Argument(help: "The host of a site or a workspace. The default is the site or the workspace of the current folder.") var host: String?

    func run() async throws {
        let target = try await siteTarget(host: host, example: "nexus open shop.test")

        guard let url = target.url else {
            FileHandle.standardError.write(Data("\(target.host) has no URL, because it does not run. See: nexus workspace list\n".utf8))
            throw ExitCode.failure
        }

        guard openWithSystem([url]) else {
            FileHandle.standardError.write(Data("macOS did not open \(url).\n".utf8))
            throw ExitCode.failure
        }

        print("\(url) opens in the browser.")
    }
}

struct EditSite: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Opens the folder of the site or the workspace of the current folder in your code editor, for example: nexus edit",
        discussion: "Nexus uses the code editor of Settings > General in the app. Without a choice, it uses the first code editor that it knows."
    )

    @Argument(help: "The host of a site or a workspace. The default is the site or the workspace of the current folder.") var host: String?

    func run() async throws {
        let folder = try await siteTarget(host: host, example: "nexus edit shop.test").projectFolder

        switch EditorChoice.current {
        case .none:
            FileHandle.standardError.write(Data("Settings > General of Nexus has no code editor. Choose one there.\n".utf8))
            throw ExitCode.failure
        case .app(let path):
            guard openWithSystem(["-a", path, folder]) else {
                FileHandle.standardError.write(Data("\(path) did not open \(folder).\n".utf8))
                throw ExitCode.failure
            }
        case .firstKnown:
            guard CodeEditors.bundleIdentifiers.contains(where: { openWithSystem(["-b", $0, folder]) }) else {
                FileHandle.standardError.write(Data("Nexus found no code editor. Choose one in Settings > General of Nexus.\n".utf8))
                throw ExitCode.failure
            }
        }

        print("\(folder) opens in the code editor.")
    }
}

func siteTarget(host: String?, example: String) async throws -> SiteTarget {
    let response = try await send(.sites)

    guard case .sites(let sites) = response else {
        try finish(response)
        throw ExitCode.failure
    }

    let folder = RealPath.of(URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory))

    do {
        return try SiteTarget.find(host: host, folder: folder, in: sites, example: example)
    } catch {
        FileHandle.standardError.write(Data("\(ErrorText.plain(error))\n".utf8))
        throw ExitCode.failure
    }
}

private func openWithSystem(_ arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/open")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    guard (try? process.run()) != nil else {
        return false
    }

    process.waitUntilExit()
    return process.terminationStatus == 0
}
