import NexusCore
import NexusMail

extension AppModel {
    // The menu bar, the settings and an open first run show their own failures. The click needs
    // this value too.
    var windowFailure: ActionFailure? {
        failure.flatMap { failure in
            switch failure.place {
            case .window, .background: failure
            case .firstRun: firstRunIsOpen ? nil : failure
            case .menuBar, .settings: nil
            }
        }
    }

    // The sheets and the alerts of the main window that the model knows, except the failure. The
    // local alerts of the screens are the attachedSheet of the window. NotificationClicks checks
    // those.
    var windowHasDialog: Bool {
        sheet != nil || errorReport?.place == .window || groupNaming != nil || removal != nil || !agents.alerts.isEmpty
    }

    // A site, a service or a mail that is gone keeps the screen as it is. Each click removes the
    // mark of the click before it.
    func show(_ target: NotificationTarget) {
        markedRow = nil

        switch target {
        case .workspace(let host, _), .site(let host):
            guard site(host) != nil else {
                return
            }

            selection = .site(host)
        case .service(let id), .database(let id, _):
            guard let service = service(id) else {
                return
            }

            show(service)
        case .mail(let id, let tag):
            filterMail(by: tag, opening: id)
            selection = .service(.mail)
        }

        switch target {
        case .workspace, .database:
            markedRow = target
        case .site, .service, .mail:
            break
        }
    }
}
