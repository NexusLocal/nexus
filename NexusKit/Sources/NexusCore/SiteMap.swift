import Foundation
import Synchronization

// A site claims a host and a folder before a workspace, as in workspaceSites() of nexusd.
public struct SiteMap: Sendable, Equatable {
    // host is the first host of the site or the workspace. It is the tag of a mail and the host of
    // a block of the dump viewer. projectFolder is the real path that
    // ProjectFolder.projectFolder(ofSiteFolder:) gives, for example the folder above public/.
    public struct Entry: Sendable, Equatable {
        public let place: DumpPlace
        public let host: String
        public let projectFolder: String?

        public init(place: DumpPlace, host: String, projectFolder: String? = nil) {
            self.place = place
            self.host = host
            self.projectFolder = projectFolder
        }

        public var location: DumpLocation {
            DumpLocation(place: place, host: host, projectFolder: projectFolder)
        }
    }

    // The .env is in the project folder, because a site on public/ keeps it one folder up.
    public struct PHPFiles: Sendable, Equatable {
        public let entry: Entry
        public let env: URL
        public let userIni: URL
    }

    public private(set) var hosts: [String: Entry]
    public private(set) var folders: [String: Entry]
    public private(set) var projectFolders: [String: Entry] = [:]
    public private(set) var phpSites: [PHPFiles] = []

    // folders has real paths without the / at the end, as RealPath gives them.
    public init(hosts: [String: Entry] = [:], folders: [String: Entry] = [:]) {
        self.hosts = hosts
        self.folders = folders
    }

    // A command runs in the project folder of a site on public/. So the project folder names the
    // site too, but only when it is not the folder of another site.
    public mutating func add(_ site: Site, place: DumpPlace) {
        let siteFolder = RealPath.of(site.folder)
        let projectFolder = ProjectFolder.projectFolder(ofSiteFolder: site.folder)
        let entry = Entry(place: place, host: site.host, projectFolder: projectFolder)

        for host in site.hosts {
            hosts[host] = hosts[host] ?? entry
        }

        folders[siteFolder] = folders[siteFolder] ?? entry

        if projectFolder != siteFolder {
            projectFolders[projectFolder] = projectFolders[projectFolder] ?? entry
        }

        guard site.kind == .php else {
            return
        }

        let env = URL(filePath: projectFolder, directoryHint: .isDirectory).appending(path: ".env")
        let userIni = URL(filePath: RealPath.of(site.documentRoot), directoryHint: .isDirectory).appending(path: ".user.ini")
        phpSites.append(PHPFiles(entry: entry, env: env, userIni: userIni))
    }

    // PHP gives the root as a real path.
    public func entry(of request: DumpedRequest) -> Entry? {
        if let entry = request.host.flatMap({ host in hosts[host] }) {
            return entry
        }

        return request.root.flatMap(entry(holding:))
    }

    public func place(of request: DumpedRequest) -> DumpPlace {
        entry(of: request)?.place ?? DumpPlace()
    }

    // A request outside every site has the place DumpPlace() without a host and a project folder.
    public func location(of request: DumpedRequest) -> DumpLocation {
        entry(of: request)?.location ?? DumpLocation()
    }

    public func entry(holding path: String) -> Entry? {
        var folder = RealPath.trimmed(path)

        while true {
            if let entry = folders[folder] ?? projectFolders[folder] {
                return entry
            }

            let parent = (folder as NSString).deletingLastPathComponent

            if parent == folder {
                return nil
            }

            folder = parent
        }
    }
}

// The receivers of the mail and of the dumps read the map on their own threads.
public final class SharedSiteMap: Sendable {
    private let map: Mutex<SiteMap>

    public init(_ map: SiteMap = SiteMap()) {
        self.map = Mutex(map)
    }

    public var current: SiteMap {
        map.withLock { current in current }
    }

    @discardableResult
    public func set(_ new: SiteMap) -> Bool {
        map.withLock { current in
            if current == new {
                return false
            }

            current = new
            return true
        }
    }
}
