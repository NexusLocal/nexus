import Darwin
import Foundation
import NexusConfig
import NexusCore
import NexusDumps
import NexusIPC

// The list of the requests of a link (group 4, 4f). nginx writes one JSON line for each request of a
// link with the option on. nexusd reads the lines into the dump store as requests with publicLink.
// It keeps the place of each line in the request log. The detail of a request comes from its line
// when the app asks for it. A PHP request of the link has the same id. So its dumps, queries and
// log lines show with it.

// The places of the requests of one link in its request log, the oldest first. A link keeps the
// newest 500, as the store does.
struct LinkRequestDetails: Sendable {
    private(set) var order: [String] = []
    private(set) var byID: [String: ShareLogWatch.Spot] = [:]

    mutating func add(_ id: String, at spot: ShareLogWatch.Spot) {
        if byID[id] == nil {
            order.append(id)
        }

        byID[id] = spot

        if order.count > DumpStore.linkRequestLimit {
            byID[order.removeFirst()] = nil
        }
    }
}

// The rules that turn a line of the request log into a request of the dump list and its detail
// (group 4, 4f). The tests use them without an engine.
enum LinkRequestReader {
    static let staticTypes: Set<String> = ["text/css", "text/javascript", "application/javascript", "application/x-javascript", "application/wasm", "application/vnd.ms-fontobject"]
    static let staticTypePrefixes = ["image/", "font/", "audio/", "video/", "application/font-", "application/x-font-"]
    static let staticExtensions = Set(ShareRequests.staticExtensions)

    // A target or a URL keeps the first 4096 bytes, as Request.php does.
    static let textBytes = 4096
    static let cutMarker = " [...]"

    // [Q1] A GET or a HEAD of a style, a script, an image, a font, a media file or a Vite module
    // that did not fail stays out of the list. One page with Vite Live loads hundreds of them. The
    // visitor count of 4b still counts them. A 304 has no type. So the extension decides for it.
    static func isStaticFile(_ line: ShareLogLine) -> Bool {
        guard line.method == "GET" || line.method == "HEAD" else {
            return false
        }

        guard line.status < 400 else {
            return false
        }

        if let type = line.contentType.map(mediaType), isStaticType(type) {
            return true
        }

        return hasStaticExtension(line.uri ?? "")
    }

    private static func mediaType(_ contentType: String) -> String {
        String(contentType.prefix { character in character != ";" }).trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func isStaticType(_ type: String) -> Bool {
        staticTypes.contains(type) || staticTypePrefixes.contains { prefix in type.hasPrefix(prefix) }
    }

    private static func hasStaticExtension(_ uri: String) -> Bool {
        let path = uri.prefix { character in character != "?" && character != "#" }
        let name = path.split(separator: "/").last ?? ""

        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return false
        }

        return staticExtensions.contains(name[name.index(after: dot)...].lowercased())
    }

    // nil for a line without method or uri, for example a line of the visitor log. host is the
    // local host of the link. So locate finds the site or the workspace. The URL has the public host.
    static func header(of line: ShareLogLine, link: ShareRecord) -> DumpedRequest? {
        guard let method = line.method, let uri = line.uri else {
            return nil
        }

        let publicHost = line.host ?? link.publicHost ?? link.host
        let visitor = line.visitor.isEmpty ? nil : line.visitor

        return DumpedRequest(
            id: line.request,
            kind: .http,
            method: method,
            target: shortened(uri),
            url: shortened("https://\(publicHost)\(uri)"),
            host: link.host,
            started: Date(timeIntervalSince1970: line.time - (line.duration ?? 0)),
            status: line.status,
            duration: line.duration,
            publicLink: PublicLinkRequest(host: link.host, visitor: visitor, size: line.size, contentType: line.contentType)
        )
    }

    static func detail(of line: ShareLogLine) -> ShareRequestDetail {
        let kept = line.body.flatMap { body in Data(base64Encoded: body) }
        let cut = (line.bodyBytes ?? 0) > (kept?.count ?? 0)

        return ShareRequestDetail(
            id: line.request,
            requestHeaders: headers(line.requestHeaders),
            requestBody: kept.flatMap { data in text(of: data, cut: cut) },
            requestBodyBytes: line.bodyBytes,
            requestBodyCut: cut,
            status: line.status,
            responseHeaders: headers(line.responseHeaders),
            size: line.size
        )
    }

    private static func headers(_ pairs: [[String]]?) -> [ShareHeader] {
        (pairs ?? []).compactMap { pair in
            pair.count == 2 ? ShareHeader(name: pair[0], value: pair[1]) : nil
        }
    }

    // A cut can split a character at the end. So the decode drops up to 3 bytes at the end of a cut
    // body before it gives up. Text that is not UTF-8 gives nil.
    private static func text(of data: Data, cut: Bool) -> String? {
        for dropped in 0...(cut ? 3 : 0) where dropped < data.count {
            if let text = String(data: data.dropLast(dropped), encoding: .utf8) {
                return text
            }
        }

        return nil
    }

    // The start of a long text at a whole character, with the marker.
    static func shortened(_ text: String) -> String {
        let bytes = Array(text.utf8)

        guard bytes.count > textBytes else {
            return text
        }

        var end = textBytes

        while end > 0, bytes[end] & 0xC0 == 0x80 {
            end -= 1
        }

        return String(decoding: bytes[..<end], as: UTF8.self) + cutMarker
    }
}

extension NexusEngine {
    // The hook of 4b: nil for a link that is not active or has the option off.
    func shareRequestCount(_ record: ShareRecord) -> Int? {
        guard record.state.isActive, record.options.keepsRequests else {
            return nil
        }

        return dumpStore.linkRequestCount(host: record.host)
    }

    // The step of 4f in prepareShare. The step of 4c runs first and checks the njs module. nginx
    // then writes into a request log that only the user can read.
    func prepareShareRequests(_ record: ShareRecord) throws {
        guard record.options.keepsRequests else {
            return
        }

        try FileManager.default.createDirectory(at: paths.shareFolder, withIntermediateDirectories: true)
        _ = try Self.writeIfChanged(ShareRequests.script, to: paths.shareRequestScript)
        try makeRequestLog(of: record)
    }

    private func makeRequestLog(of record: ShareRecord) throws {
        Darwin.close(try AppendingFile.open(paths.shareRequestLog(record.id), mode: 0o600))
    }

    // The active links with the list on. A link gets its details here. So a line of a link that
    // ended goes nowhere. The app and the page get linkHosts with the next list.
    func watchLinkRequests() async {
        let records = await stateStore.current().shares.filter { $0.state.isActive && $0.options.keepsRequests }
        let ids = Set(records.map(\.id))
        let hosts = records.map(\.host).sorted()

        linkRequestDetails = linkRequestDetails.filter { id, _ in ids.contains(id) }

        for record in records where linkRequestDetails[record.id] == nil {
            linkRequestDetails[record.id] = LinkRequestDetails()
        }

        if !records.isEmpty || linkRequestLogWatch != nil {
            for record in records where !FileManager.default.fileExists(atPath: paths.shareRequestLog(record.id).path(percentEncoded: false)) {
                try? makeRequestLog(of: record)
            }

            let watch = linkRequestLogWatch ?? ShareLogWatch { [weak self] id, lines in
                Task { await self?.linkRequestLinesArrived(id: id, lines: lines) }
            }

            linkRequestLogWatch = watch
            watch.watch(Dictionary(records.map { (paths.shareRequestLog($0.id).path(percentEncoded: false), $0.id) }) { first, _ in first })
        }

        guard hosts != linkListHosts else {
            return
        }

        linkListHosts = hosts
        await publishDumpList()
    }

    // The handler of the watch. A late line after the end of a link goes nowhere.
    func linkRequestLinesArrived(id: String, lines: [ShareLogWatch.Line]) async {
        guard let record = await stateStore.current().share(id: id), record.state.isActive, record.options.keepsRequests else {
            return
        }

        guard var details = linkRequestDetails[id] else {
            return
        }

        var added = false

        for logged in lines where !LinkRequestReader.isStaticFile(logged.line) {
            guard let header = LinkRequestReader.header(of: logged.line, link: record) else {
                continue
            }

            details.add(header.id, at: logged.spot)
            dumpStore.addLinkRequest(header)
            added = true
        }

        linkRequestDetails[id] = details

        if added {
            dumpsChanged()
        }
    }

    // The detail comes from the line in the request log. The end of the link deletes that log.
    func shareRequest(id: String) -> NexusResponse {
        for (shareID, details) in linkRequestDetails {
            if let spot = details.byID[id], let line = ShareLogWatch.line(at: spot, in: paths.shareRequestLog(shareID)) {
                return .shareRequest(LinkRequestReader.detail(of: line))
            }
        }

        return .failure(message: LinkRequestText.detailGone)
    }

    // [Q3] "Clear…" with the filter of a link and nexus dumps --public-link --clear. A clear before
    // the load would remove nothing. The requests of the file would then come back.
    func clearLinkRequests(host: String?) async -> NexusResponse {
        guard dumpStore.isLoaded else {
            return .failure(message: DumpList.notLoadedText)
        }

        let removed = dumpStore.removeLinkRequests(hosts: host.map { [$0] })

        for record in await stateStore.current().shares where host == nil || record.host == host {
            if linkRequestDetails[record.id] != nil {
                linkRequestDetails[record.id] = LinkRequestDetails()
            }
        }

        dumpsChanged()

        guard removed > 0 else {
            return .done(message: "The list has no requests to remove.")
        }

        return .done(message: "Nexus removed \(Count.text(removed, "request")).")
    }

    // [Q4] The end of links: the requests of the links lose their link. A request with entries stays
    // as a normal request. The details go. 4b deletes the request log. endShares watches the logs
    // again after the reload of nginx.
    func endLinkRequests(of records: [ShareRecord]) {
        let ended = records.filter(\.options.keepsRequests)

        guard !ended.isEmpty else {
            return
        }

        dumpStore.endLinkRequests(hosts: Set(ended.map(\.host)))

        for record in ended {
            linkRequestDetails[record.id] = nil
        }

        dumpsChanged()
    }

    // [Q5] A new start of nexusd deletes the list of each link, also of an own-domain link that opens
    // again (4h). The list lives only while one run of nexusd keeps the link open.
    func forgetLinkRequestsOfEarlierRun() async {
        for record in await stateStore.current().shares {
            try? FileManager.default.removeItem(at: paths.shareRequestLog(record.id))
        }

        await watchLinkRequests()
    }
}
