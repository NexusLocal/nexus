import Foundation
import NexusCore
import NexusLaravel
import NexusRuntime

// The configuration probe (D43). The application gets the PHP of its site. Outside a site, the
// default for a new site applies. The caller can name another PHP.
extension NexusEngine {
    func probeConfiguration(folder path: String, php requested: String?) async throws -> LaravelConfiguration {
        let folder = URL(filePath: path, directoryHint: .isDirectory)

        guard let root = LaravelProject.root(containing: folder) else {
            throw ProbeError.notLaravel(folder: path)
        }

        let state = await stateStore.current()
        let sites = resolvedSites(state).map(\.site)
        let location = ProjectFolder.locate(root, in: sites) ?? ProjectFolder.locate(folder, in: sites)
        let installed = await installer.installedRuntimes()
        let line = try requested ?? phpLine(for: location, state: state, installed: installed)
        let php = try await phpCommand(installedPHP(line, in: installed))

        return try await ConfigurationProbe(php: URL(filePath: php.executable), environment: php.environment).run(root: root)
    }

    // The Databases section of the Site screen (owner, 2026-11-07). Only a Laravel site has a
    // configuration that the probe reads. The application can be in a subfolder of the site folder.
    func siteDatabases(host: String) async throws -> [SiteDatabase] {
        let state = await stateStore.current()

        guard let site = resolvedSites(state).map(\.site).first(where: { $0.hosts.contains(host) }) else {
            throw RuntimeError.unsupported("Nexus has no site \(host).")
        }

        guard site.kind == .php, PHPProject.type(of: site) == .laravel, let root = LaravelProject.root(containing: URL(filePath: ProjectFolder.projectFolder(of: site), directoryHint: .isDirectory)) else {
            return []
        }

        let configuration = try await shownConfiguration(of: site, folder: RealPath.of(root))
        var instances: [SiteDatabases.Instance] = []

        for tools in await databaseRuntimes() {
            instances.append(SiteDatabases.Instance(id: tools.id, usesMySQLProtocol: tools.kind.usesMySQLProtocol, port: try await port(of: tools)))
        }

        return SiteDatabases.list(configuration, instances: instances)
    }

    // The Site screen asks for the configuration each time it opens, and the probe starts PHP. So
    // the answer stays until a file that the probe reads changes, or the PHP version of the site.
    func shownConfiguration(of site: Site, folder: String) async throws -> LaravelConfiguration {
        let files = "\(site.usedPHP ?? "") \(Self.configurationDigest(of: folder, in: folder)) \(Self.digest(of: "composer.lock", in: folder) ?? "")"

        if let shown = shownConfigurations[folder], shown.files == files {
            return shown.configuration
        }

        let configuration = try await configuration(of: site, folder: folder)
        shownConfigurations[folder] = (files, configuration)
        return configuration
    }
}
