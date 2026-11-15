import Foundation
import NexusConfig
import NexusCore
import NexusIPC
import NexusRuntime

// The custom nginx or Apache lines of a PHP site (owner, 2026-11-14).
extension NexusEngine {
    func siteLines(host: String) async throws -> [String] {
        try phpSite(host, in: await stateStore.current()).serverLines ?? []
    }

    // nginx -t or httpd -t checks the new lines with the whole configuration. When it refuses them,
    // the old lines stay in the state and in the files. So the running servers keep them. A site
    // that does not run is not in the configuration, so nothing could check its lines. Empty lines
    // also remove the stored lines of the other webserver. Else wrong stored lines could stop a
    // change of the webserver, and no editor shows them.
    func setSiteLines(host: String, lines: [String]) async throws -> String {
        let site = try phpSite(host, in: await stateStore.current())

        if let problem = Self.problem(of: site, installed: await installer.installedRuntimes()) {
            throw RuntimeError.unsupported("\(host) does not run. So Nexus cannot check its new lines. \(problem)")
        }

        let server = site.server
        let kept = Self.siteLines(lines)

        let change: @Sendable (inout Site) -> Void = { site in
            if kept == nil {
                site.nginxLines = nil
                site.apacheLines = nil
            } else {
                site.serverLines = kept
            }
        }

        var edited = site
        change(&edited)
        let added = edited
        let store: @Sendable (inout EngineState) -> Void = { state in
            Self.changeOrAdd(added, in: &state, change: change)
        }

        do {
            _ = try await changeWeb(.setting, store)
        } catch let failure as ConfigCheckFailure where failure.server == server {
            let error = failure.firstError

            switch error.place(inLinesOf: await linesFiles(of: host, server: server), lineCount: kept?.count ?? 0) {
            case .siteLines(let line):
                throw SiteLinesError(host: host, server: server, line: line, message: error.message)
            // An error in the lines of another site is no error of these lines. So it stays a plain
            // failure with the whole text, which names that file.
            case .otherSite:
                throw failure
            // An error in a file of Nexus, for example a second location /. The old files are back
            // now. When they fail too, the new lines are not the cause.
            case .nexus:
                guard await writtenConfigPasses(server) else {
                    throw failure
                }

                throw SiteLinesError(host: host, server: server, line: nil, message: error.message)
            }
        }

        let running = await supervisor.state(of: server.serviceID)?.isActive == true

        return running
            ? "\(host) runs with the new \(server.displayName) lines."
            : "\(host) gets the new \(server.displayName) lines at the next start of \(server.displayName)."
    }

    // A change of the webserver brings back the stored lines of that webserver. When the check
    // refuses them, the text says how to remove them.
    func storedLinesRefusal(_ failure: ConfigCheckFailure, host: String) async -> RuntimeError? {
        let error = failure.firstError
        let server = failure.server
        let lineCount = (try? resolvedSite(host, in: await stateStore.current()))?.lines(of: server)?.count ?? 0

        guard case .siteLines(let line) = error.place(inLinesOf: await linesFiles(of: host, server: server), lineCount: lineCount) else {
            return nil
        }

        return RuntimeError.unsupported("\(server.programName) refused the stored \(server.displayName) lines of \(host). \(LineErrorText.text(error.message, line: line)). Remove them first with nexus site lines \(host) --clear, or save empty lines on the Site screen. Then change the webserver again.")
    }

    // The workspaces of a site get its lines. So an error in their files is an error of these lines.
    private func linesFiles(of host: String, server: WebServer) async -> Set<URL> {
        let workspaces = workspaceSites(await stateStore.current())
        let workspaceHosts = zip(workspaces.sites, workspaces.places).filter { $0.1.site == host }.map(\.0.host)

        return Set(([host] + workspaceHosts).map { paths.siteLinesFile($0, server: server) })
    }

    // A site of a parked folder counts too. It becomes an added site, as with nexus site edit.
    private func phpSite(_ host: String, in state: EngineState) throws -> Site {
        let site = try resolvedSite(host, in: state)

        guard site.kind == .php else {
            throw RuntimeError.unsupported("Only a PHP site has custom nginx or Apache lines. \(host) runs as \(site.kind == .node ? "a Node.js app" : "a proxy").")
        }

        return site
    }

    // A line break in a line starts a new line, also the CRLF of a Windows text. Only empty lines
    // give no lines, so the site gets no file and no include.
    static func siteLines(_ lines: [String]) -> [String]? {
        let split = lines.flatMap { $0.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") }

        return split.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } ? nil : split
    }
}
