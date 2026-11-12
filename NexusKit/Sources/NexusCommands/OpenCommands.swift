import ArgumentParser
import Foundation
import NexusCore
import NexusIPC
import NexusMCP

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

        try await openWithSystem(url)
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

        let choice = EditorChoice.current

        guard choice != .none else {
            FileHandle.standardError.write(Data("Settings > General of Nexus has no code editor. Choose one there.\n".utf8))
            throw ExitCode.failure
        }

        guard await choice.open(folder) else {
            let problem = if case .app(let path) = choice { "\(path) did not open \(folder)." } else { "Nexus found no code editor. Choose one in Settings > General of Nexus." }
            FileHandle.standardError.write(Data("\(problem)\n".utf8))
            throw ExitCode.failure
        }

        print("\(folder) opens in the code editor.")
    }
}

// Opens a URL with macOS, or ends the command with an error.
func openWithSystem(_ url: String) async throws {
    guard await SystemOpen.run([url]) else {
        FileHandle.standardError.write(Data("macOS did not open \(url).\n".utf8))
        throw ExitCode.failure
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
