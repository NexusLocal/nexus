import Foundation
import NexusCore
import NexusLaravel

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
}
