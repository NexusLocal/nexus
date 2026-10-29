import AppKit
import NexusCore
import NexusIPC
import NexusRuntime

// The Packages screen, the tasks of nexusd and the import of a database (part 6f).
extension AppModel {
    // A note shows when the security fixes end within this time, and after they ended (D12).
    static let securityNoteMonths = 6

    // The update check runs at launch, once a day and on a click. Without the automatic check
    // in Settings > Updates, it runs only on a click and when the Packages screen opens for the
    // first time.
    func watchPackageUpdates() {
        Task { [weak self] in
            repeat {
                if AppPreference.isOn(AppPreference.checkPackageUpdates) {
                    await self?.checkPackages()
                }
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            } while self != nil
        }
    }

    func checkPackages() async {
        guard isLive, !checkingPackages else {
            return
        }

        checkingPackages = true
        lastPackageCheck = .now
        defer { checkingPackages = false }

        switch await outcome(of: .available) {
        case .answer(.available(let packages)):
            manifestPackages = packages
            packagesProblem = nil
            packagesChecked = Date.now.formatted(date: .omitted, time: .shortened)
        case .failure(let message):
            packagesProblem = message
        default:
            break
        }

        await loadInstalledRuntimes()

        if AppPreference.isOn(AppPreference.installPackageUpdates) {
            installUpdates()
        }
    }

    // An update of a running service starts it again (part 6f).
    func installUpdates() {
        for package in packages {
            if case .update = package.state {
                install(package)
            }
        }
    }

    var installedProblemText: String? {
        installedProblem.map { "Nexus cannot read the installed packages. \($0)" }
    }

    func loadInstalledRuntimes() async {
        switch await outcome(of: .installed) {
        case .answer(.installed(let runtimes)):
            installedRuntimes = runtimes
            installedLoaded = true
            installedProblem = nil
            rebuildPackages()
        case .failure(let message):
            installedProblem = message
        default:
            break
        }
    }

    // One row for each version line of the manifest, and one for each installed line that the
    // manifest does not have any more.
    func rebuildPackages() {
        guard isLive else {
            return
        }

        let installed = Dictionary(installedRuntimes.map { ("\($0.name)-\($0.line)", $0) }, uniquingKeysWith: { first, _ in first })
        let offered = Set(manifestPackages.map(\.id))
        let installedPHP = installedRuntimes.filter { $0.name == "php" }.count

        var items = manifestPackages.map { package in
            packageItem(name: package.name, line: package.line, offered: package, installed: installed[package.id], installedPHP: installedPHP)
        }

        for runtime in installedRuntimes where !offered.contains("\(runtime.name)-\(runtime.line)") {
            items.append(packageItem(name: runtime.name, line: runtime.line, offered: nil, installed: runtime, installedPHP: installedPHP))
        }

        packages = items
    }

    private func packageItem(name: String, line: String, offered: ManifestPackage?, installed: InstalledRuntime?, installedPHP: Int) -> PackageItem {
        let version = installed?.version ?? offered?.version ?? ""
        let task = tasks.first { task in
            guard case .install(let taskName, let taskLine, _, _) = task.work else {
                return false
            }

            return taskName == name && taskLine == line
        }

        let state: PackageState
        if let task {
            state = .downloading(task.fraction)
        } else if startingDownloads.contains("\(name)-\(line)") {
            state = .downloading(0)
        } else if let installed, let offered, !installed.isSameBuild(as: offered) {
            state = .update(offered.version)
        } else if installed != nil {
            state = .installed
        } else {
            state = .available
        }

        var item = PackageItem(
            section: Self.packageSection(name),
            package: name,
            line: line,
            name: Self.packageName(name, line: line, version: offered?.version ?? version),
            version: version,
            state: state,
            lts: offered?.lts ?? false,
            required: name == "nginx" || name == "composer" || name == "php" && installed != nil && installedPHP == 1,
            taskID: task?.id,
            downloadSize: offered?.size
        )

        if let end = offered?.securityEndDate, let soon = Calendar.current.date(byAdding: .month, value: Self.securityNoteMonths, to: .now), end <= soon {
            item.securityEnd = offered?.securityEnd
            item.securityEnded = Date.now >= end.addingTimeInterval(24 * 60 * 60)
        }

        return item
    }

    static func packageSection(_ name: String) -> String {
        switch name {
        case "nginx", "httpd": "Webservers"
        case "php": "PHP"
        case "mysql": "MySQL"
        case "mariadb": "MariaDB"
        case "postgresql": "PostgreSQL"
        case "redis": "Redis"
        case "node", "composer": "Node and Composer"
        default: "Other"
        }
    }

    static func packageTitle(_ name: String) -> String {
        switch name {
        case "nginx": "nginx"
        case "httpd": "Apache"
        case "composer": "Composer"
        case "node": "Node"
        default: ServiceKind(package: name)?.title ?? name
        }
    }

    // Redis 8 is the newest Redis 8. So its row shows the version line of its build, for
    // example Redis 8.10.
    static func packageName(_ name: String, line: String, version: String = "") -> String {
        switch name {
        case "redis" where line == "8" && !version.isEmpty: "Redis \(version.split(separator: ".").prefix(2).joined(separator: "."))"
        case "composer": "Composer"
        default: "\(packageTitle(name)) \(line)"
        }
    }

    // An update is an install of the newest build of an installed version line. nexusd starts
    // a service that runs again after the update.
    func install(_ package: PackageItem, from place: ActionPlace = .window) {
        let key = package.id
        let failure = package.isInstalled ? "\(package.name) did not update" : "\(package.name) did not install"
        startingDownloads.insert(key)
        rebuildPackages()

        Task {
            await perform(.install(name: package.package, line: package.line), failure: failure, place: place)
            startingDownloads.remove(key)
            await loadInstalledRuntimes()
        }
    }

    func remove(_ package: PackageItem) {
        Task {
            await perform(.remove(name: package.package, line: package.line), failure: "\(package.name) was not removed", place: .window)
            await loadInstalledRuntimes()
        }
    }

    func stopTask(_ id: String) {
        send(.stopTask(id: id), failure: "The task did not stop", place: .window)
    }

    func showPackagesFolder() {
        let folder = URL.applicationSupportDirectory.appending(path: "Nexus/runtimes", directoryHint: .isDirectory)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    // The tasks of nexusd give the activities and the progress of the package rows.
    // A download from the command line ends without an answer to the app. Node has no service
    // either. So the end of a download loads the installed runtimes again. The rows of the
    // packages change only with a download, not with each step of a database copy.
    func show(_ list: TaskList) {
        let installTasks = list.tasks.filter(\.isInstall)
        let rowsChange = installTasks != tasks.filter(\.isInstall)
        let ended = Self.downloads(in: tasks).subtracting(Self.downloads(in: list.tasks))
        tasks = list.tasks
        activities = list.tasks.map { task in
            ActivityItem(id: task.id, title: title(of: task), shortTitle: shortTitle(of: task), progress: task.fraction, taskID: task.id)
        }

        startingDownloads.subtract(Self.downloads(in: list.tasks))

        if rowsChange {
            rebuildPackages()
        }

        if !ended.isEmpty {
            Task { await loadInstalledRuntimes() }
        }
    }

    private static func downloads(in tasks: [TaskInfo]) -> Set<String> {
        Set(tasks.compactMap { task -> String? in
            guard case .install(let name, let line, _, _) = task.work else {
                return nil
            }

            return "\(name)-\(line)"
        })
    }

    private func title(of task: TaskInfo) -> String {
        switch task.work {
        case .install(let name, let line, let version, let update):
            let package = Self.packageName(name, line: line, version: version)
            return update ? "Updating \(package) to \(version)" : "Downloading \(package)"
        case .copyDatabase(let database, let instance, let name):
            let into = service(instance)?.name ?? instance
            return name == database ? "Importing \(database) into \(into)" : "Importing \(database) into \(into) as \(name)"
        }
    }

    private func shortTitle(of task: TaskInfo) -> String {
        switch task.work {
        case .install:
            title(of: task)
        case .copyDatabase(_, _, let name):
            "Importing \(name)"
        }
    }

    // The databases on the other server for the import sheet. The answer is the list, or the
    // reason why nexusd cannot read it.
    func sourceDatabases(on server: DatabaseServer, for instance: String) async -> Result<[DatabaseSize], ImportProblem> {
        switch await outcome(of: .sourceDatabases(source: server, instance: instance)) {
        case .answer(.databaseSizes(let sizes)):
            .success(sizes)
        case .failure(let message):
            .failure(ImportProblem(message: message))
        default:
            .success([])
        }
    }

    static func importKey(instance: String, name: String) -> String {
        "\(instance) \(name)"
    }

    func importTask(instance: String, name: String) -> TaskInfo? {
        tasks.first { task in
            guard case .copyDatabase(_, let taskInstance, let taskName) = task.work else {
                return false
            }

            return taskInstance == instance && taskName == name
        }
    }

    // The import goes on when the user closes the sheet. A failure then shows as an alert in
    // the window. A copy that the user stopped shows nothing.
    // The sheet that starts the import shows its end while the sheet is open. A success then
    // closes the sheet. A stopped copy with "Replace" can have dropped the old database. So
    // with the sheet closed, that stop shows as an alert.
    func startImport(_ copy: DatabaseCopy) {
        let key = Self.importKey(instance: copy.instance, name: copy.name ?? copy.database)
        runningImports.insert(key)
        importResults[key] = nil
        importInSheet = key

        Task {
            let outcome = await outcome(of: .copyDatabase(copy))
            runningImports.remove(key)
            let inSheet = importInSheet == key

            switch outcome {
            case .answer(.done):
                if inSheet {
                    importInSheet = nil
                    sheet = nil
                }
                if let service = service(copy.instance) {
                    loadDatabases(of: service)
                }
                Notifier.post("The import is done", "\(copy.name ?? copy.database) is in \(service(copy.instance)?.name ?? copy.instance) now.", setting: AppPreference.notifyImportDone)
            case .answer(.stopped(let message)):
                if inSheet {
                    importResults[key] = .stopped(message)
                } else if copy.replace {
                    failure = ActionFailure(title: "The import of \(copy.database) stopped", message: message, place: .window)
                }
            case .failure(let message):
                showImportFailure(message, of: copy, key: key, inSheet: inSheet)
            case .portInUse(let conflict):
                showImportFailure(conflict.description, of: copy, key: key, inSheet: inSheet)
            default:
                break
            }
        }
    }

    private func showImportFailure(_ message: String, of copy: DatabaseCopy, key: String, inSheet: Bool) {
        Notifier.post("\(copy.database) was not imported", message, setting: AppPreference.notifyImportDone)

        guard inSheet else {
            failure = ActionFailure(title: "\(copy.database) was not imported", message: message, place: .window)
            return
        }

        importResults[key] = .failed(message)
    }
}

enum ImportResult: Equatable {
    case failed(String)
    case stopped(String)
}

struct ImportProblem: Error {
    let message: String
}

extension TaskInfo {
    var isInstall: Bool {
        if case .install = work {
            return true
        }

        return false
    }

    // A database copy has an estimate as its total. So it stays below 100 percent until it ends.
    var fraction: Double {
        guard let total, total > 0 else {
            return 0
        }

        return min(Double(completed) / Double(total), 0.99)
    }
}
