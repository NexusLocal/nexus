import Foundation
import NexusCore
import NexusDumps
import NexusIPC

// The web page of the logs (group 7) on the server of the dumps page. It shows the log files of
// the app of one site or workspace, as the Logs screen does. The page only reads, except "open in
// the editor". The places come from the same list of sites as read_log and nexus logs. The files
// are read outside the actor.
extension NexusEngine {
    nonisolated func answerLogPage(_ page: PageRequest) async -> PageResponse {
        switch (page.method, page.path) {
        case ("GET", "/api/logs/places"):
            return .json(LogPagePlaces(places: await logPagePlaces()))
        case ("GET", "/api/logs/entries"):
            let request = LogPageQuery(page.query)

            guard let place = await logPagePlace(request.place) else {
                return Self.unknownLogPlace(request.place)
            }

            return logPageStore.entries(of: place, paths: paths, request: request)
        case ("GET", "/api/logs/entry"):
            guard let file = page.query["file"], let offset = UInt64(page.query["offset"] ?? "") else {
                return .message("Name a file and the offset of an entry.", status: 400)
            }

            let name = page.query["place"] ?? ""

            guard let place = await logPagePlace(name) else {
                return Self.unknownLogPlace(name)
            }

            return logPageStore.detail(of: place, paths: paths, fileKey: file, offset: offset)
        case ("POST", "/api/logs/open"):
            guard let body = try? JSONDecoder().decode(LogPageOpen.self, from: page.body) else {
                return .message("Name an entry.", status: 400)
            }

            return await openLogPageFile(body)
        default:
            return .message("The page of the logs has no \(page.path).", status: 404)
        }
    }

    nonisolated func logPagePlaces() async -> [LogPlace] {
        await logPageStore.places {
            await siteInfo().flatMap(\.logPlaces)
        }
    }

    private nonisolated func logPagePlace(_ id: String) async -> LogPlace? {
        await logPagePlaces().first { $0.id == id }
    }

    private static func unknownLogPlace(_ id: String) -> PageResponse {
        .message(id.isEmpty ? "Name a site or a workspace." : "Nexus has no site or workspace \(id).", status: 404)
    }

    // Only a file that nexusd finds itself opens: the log file, or a file of the stack trace in the
    // project folder of the place. The activity log names each open, as for the dumps page.
    private nonisolated func openLogPageFile(_ body: LogPageOpen) async -> PageResponse {
        guard let place = await logPagePlace(body.place) else {
            return Self.unknownLogPlace(body.place)
        }

        let response: PageResponse

        switch logPageStore.openTarget(of: place, paths: paths, request: body) {
        case .refused(let refusal):
            response = refusal
        case .file(let path, let line):
            response = await logPageStore.open(path, line: line) ? .message("\(path) opens in your code editor.", status: 200) : .message("macOS did not open \(path).", status: 409)
        }

        let outcome = response.status == 200 ? "done" : "failed: \(Self.message(of: response))"
        activity?.write("request", "openLogFile \(place.id) (log page): \(outcome)")
        return response
    }

    private static func message(of response: PageResponse) -> String {
        (try? JSONDecoder().decode([String: String].self, from: response.body))?["message"] ?? "status \(response.status)"
    }
}
