#if DEBUG
import AppKit

// Launch arguments of a debug build that open one screen. They let a check of the look work
// without clicks: --screen service:mysql --sheet port --appearance light --settings network
// The services of the sample data, such as the port problem of --sheet port, need --sample.
enum DebugLaunch {
    static func apply(to model: AppModel, openSettings: () -> Void) {
        HangWatchdog.shared.start()
        NSApplication.shared.activate()

        if let tab = value(of: "--settings") {
            UserDefaults.standard.set(tab, forKey: SettingsWindow.tabKey)
            openSettings()
        }

        if let appearance = value(of: "--appearance") {
            NSApplication.shared.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }

        if let screen = value(of: "--screen") {
            model.selection = selection(screen)
        }

        if let version = value(of: "--version"), let service = model.service(version) {
            model.selectedVersion[service.kind] = service.id
        }

        switch value(of: "--sheet") {
        case "add-site": model.sheet = .addSite
        case "import": model.sheet = .importDatabase(instance: "mysql-8.0")
        case "port":
            if let blocked = model.blockedService {
                model.sheet = .portInUse(service: blocked.service.id, holder: blocked.holder)
            }
        default: break
        }
    }

    private static func selection(_ screen: String) -> SidebarItem {
        let parts = screen.split(separator: ":", maxSplits: 1).map(String.init)

        switch (parts.first, parts.last) {
        case ("site", let host?): return .site(host)
        case ("service", let kind?): return ServiceKind(rawValue: kind).map(SidebarItem.service) ?? .overview
        case ("packages", _): return .packages
        case ("command-line", _): return .commandLine
        default: return .overview
        }
    }

    private static func value(of name: String) -> String? {
        let arguments = CommandLine.arguments

        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
            return nil
        }

        return arguments[index + 1]
    }
}
#endif
