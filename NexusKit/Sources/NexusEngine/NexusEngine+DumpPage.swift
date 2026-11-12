import Foundation
import NexusCore
import NexusDumps
import NexusIPC
import NexusRuntime
import NexusSupervisor

// The web page of the dumps. It shows the same list and tree as the Dumps screen. The page can also clear and remove dumps and open the file of a dump in the code editor.
// Each action of the page is a request of nexusd, as an action of the app is. The page gets the
// same dump events as the app, as server-sent events. A page that opens gets the whole list first.
extension NexusEngine {
    // The port is in the port registry, so a bookmark of the page keeps working. macOS lets a
    // program bind 127.0.0.1 while another program listens on all addresses of the same port. So
    // the port is checked first, as for the SMTP receiver. A port that another program holds
    // leaves the app without the button "Open in Browser". Each read of the dump state tries again
    // without a wait, for example when the Dumps screen shows. The activity log gets each new
    // problem once.
    func startDumpPage(portWait: Duration = .seconds(1)) async {
        guard servesDumpPage, dumpPageServer == nil else {
            return
        }

        do {
            let port = try await stateStore.port(for: ServiceID.dumpPagePortKey, standard: ServiceID.dumpPageStandardPort)
            let isFree = port == 0 ? true : await PortInspector.becomesFree(port, within: portWait)

            guard isFree else {
                let owner = PortInspector.owner(of: port).map { " \($0.command) uses it." } ?? ""
                throw RuntimeError.unsupported("Port \(port) is in use.\(owner)")
            }

            let server = DumpPageServer(port: port) { [weak self] in
                Task { await self?.sendListToDumpPages() }
            } handle: { [weak self] request in
                await self?.answerDumpPage(request) ?? .message("nexusd stops.", status: 503)
            }

            try server.start()
            dumpPageServer = server
            dumpPageProblem = nil
        } catch {
            let problem = "The web page of the dumps does not run. \(ErrorText.plain(error))"

            if problem != dumpPageProblem {
                activity?.write("dumps", problem)
            }

            dumpPageProblem = problem
        }
    }

    func stopDumpPage() {
        dumpPageServer?.stop()
        dumpPageServer = nil
        dumpPageProblem = nil
    }

    // Each page gets the list again. That does no harm, as for a new watcher of the app. The list
    // holds each change that went out before it, and each later change comes after it.
    private func sendListToDumpPages() async {
        dumpPageServer?.send(event: "list", value: await dumpList(place: nil))
    }

    func sendToDumpPages(_ event: NexusEvent) {
        guard let server = dumpPageServer, server.hasPages else {
            return
        }

        switch event {
        case .dumpList(let list):
            server.send(event: "list", value: list)
        case .dumpChanges(let change):
            server.send(event: "change", value: change)
        default:
            return
        }
    }

    private enum PageRoute {
        case request(NexusRequest)
        case refused(PageResponse)
    }

    private struct PageClear: Decodable {
        let all: Bool?
        let place: DumpPlace?
    }

    private struct PageDump: Decodable {
        let number: Int
    }

    private struct PageRequestID: Decodable {
        let id: String
    }

    // The answer leaves the actor before its JSON is made. The activity log names each action of
    // the page, as it names each action of the app.
    nonisolated func answerDumpPage(_ page: PageRequest) async -> PageResponse {
        switch Self.route(of: page) {
        case .refused(let refusal):
            return refusal
        case .request(let request):
            let response = await handle(request)

            if !request.onlyReads {
                activity?.write("request", "\(request.activitySummary) (dump page): \(response.activitySummary)")
            }

            return Self.pageAnswer(response)
        }
    }

    private static func route(of page: PageRequest) -> PageRoute {
        switch (page.method, page.path) {
        case ("GET", "/api/dumps"):
            guard let id = page.query["request"], let after = Int(page.query["after"] ?? "0") else {
                return .refused(.message("Name a request.", status: 400))
            }

            return .request(.requestDumps(request: id, afterNumber: after))
        case ("POST", "/api/clear"):
            guard let body = decoded(PageClear.self, from: page), body.all == true || body.place != nil else {
                return .refused(.message("Name the dumps to clear.", status: 400))
            }

            return .request(.clearCaughtDumps(place: body.all == true ? nil : body.place))
        case ("POST", "/api/remove-dump"):
            return decoded(PageDump.self, from: page).map { .request(.removeCaughtDump(number: $0.number)) } ?? .refused(.message("Name a dump.", status: 400))
        case ("POST", "/api/remove-request"):
            return decoded(PageRequestID.self, from: page).map { .request(.removeDumpedRequest(id: $0.id)) } ?? .refused(.message("Name a request.", status: 400))
        case ("POST", "/api/open"):
            return decoded(PageDump.self, from: page).map { .request(.openCaughtDumpFile(number: $0.number)) } ?? .refused(.message("Name a dump.", status: 400))
        default:
            return .refused(.message("The page of the dumps has no \(page.path).", status: 404))
        }
    }

    // Only the file of a dump in the store opens, never a path from the request. The actor is free
    // while macOS opens the file.
    func openCaughtDumpFile(number: Int) async -> NexusResponse {
        guard let dump = dumpStore.dump(number: number), let file = dump.file else {
            return .failure(message: "Nexus has no file of this dump.")
        }

        guard FileManager.default.fileExists(atPath: file) else {
            return .failure(message: "\(file) does not exist anymore.")
        }

        guard await EditorChoice.current.open(file, line: dump.line) else {
            return .failure(message: "macOS did not open \(file).")
        }

        return .done(message: "\(file) opens in your code editor.")
    }

    private static func decoded<Body: Decodable>(_ type: Body.Type, from page: PageRequest) -> Body? {
        try? JSONDecoder().decode(type, from: page.body)
    }

    private static func pageAnswer(_ response: NexusResponse) -> PageResponse {
        switch response {
        case .done(let message):
            .message(message, status: 200)
        case .failure(let message):
            .message(message, status: 409)
        case .caughtDumps(let dumps):
            .json(dumps)
        default:
            .message("nexusd gave another answer.", status: 500)
        }
    }
}
