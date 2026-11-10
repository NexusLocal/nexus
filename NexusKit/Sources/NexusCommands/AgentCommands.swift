import ArgumentParser
import Foundation
import NexusCore
import NexusMCP

// These commands run the read tools of the MCP server. So an agent without MCP gets the same help
// in the terminal.
enum ReadTool {
    static func run(_ name: String, _ arguments: [String: JSONValue], json: Bool, lines: (JSONValue) -> [String]) async throws {
        let folder = RealPath.of(URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory))
        let result = await NexusToolbox(folder: folder).look(name, arguments: arguments)

        guard !result.isError, let structured = result.structured else {
            FileHandle.standardError.write(Data("\(result.text)\n".utf8))
            throw ExitCode.failure
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(structured), as: UTF8.self))
            return
        }

        lines(structured).forEach { print($0) }
    }

    static func arguments(_ values: [String: String?]) -> [String: JSONValue] {
        values.compactMapValues { $0.map(JSONValue.string) }
    }

    static func text(_ value: JSONValue?) -> String? {
        value?.text
    }

    static func list(_ value: JSONValue?) -> [JSONValue] {
        value?.array ?? []
    }
}

extension SiteCommand {
    struct Info: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Shows the URL, the databases with the password, the test database, the mail and the workspaces of the site or the workspace of the current folder.")

        @Argument(help: "A host or a folder. The default is the site or the workspace of the current folder.") var site: String?
        @Flag(help: "Prints JSON, as the MCP tool site_info gives it.") var json = false

        func run() async throws {
            try await ReadTool.run("site_info", ReadTool.arguments(["site": site]), json: json) { info in
                var lines = [
                    "Site       \(ReadTool.text(info["site"]) ?? "")",
                    "URL        \(ReadTool.text(info["url"]) ?? "none")",
                    "Folder     \(ReadTool.text(info["folder"]) ?? "")",
                    "Type       \(ReadTool.text(info["type"]) ?? "")",
                ]

                if let workspace = info["workspace"], case .object = workspace {
                    lines.insert("Workspace  \(ReadTool.text(workspace["name"]) ?? "") (\(ReadTool.text(workspace["state"]) ?? ""))", at: 1)
                }

                ReadTool.text(info["php"]).map { lines.append("PHP        \($0) with \(ReadTool.text(info["webServer"]) ?? "")") }
                ReadTool.text(info["node"]).map { lines.append("Node.js    \($0)") }

                for database in ReadTool.list(info["databases"]) {
                    let port = ReadTool.text(database["port"]).map { ", port \($0)" } ?? ""
                    let account = ReadTool.text(database["user"]).map { ", user \($0) with password \"\(ReadTool.text(database["password"]) ?? "")\"" } ?? ""
                    lines.append("Database   \(ReadTool.text(database["database"]) ?? "") on \(ReadTool.text(database["server"]) ?? "")\(port)\(account)")
                }

                ReadTool.text(info["mail"]?["note"]).map { lines.append("Mail       \($0)") }
                ReadTool.text(info["testDatabase"]?["note"]).map { lines.append("Tests      \($0)") }

                for workspace in ReadTool.list(info["workspaces"]) {
                    lines.append("Workspace  \(ReadTool.text(workspace["name"]) ?? "")  \(ReadTool.text(workspace["url"]) ?? "")  \(ReadTool.text(workspace["state"]) ?? "")")
                }

                ReadTool.text(info["problem"]).map { lines.append("Problem    \($0)") }
                return lines
            }
        }
    }
}

struct Errors: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Shows the newest errors of the site or the workspace of the current folder: the Laravel log, the PHP errors and the requests with status 500 or higher.")

    @Argument(help: "A host or a folder. The default is the site or the workspace of the current folder.") var site: String?
    @Option(help: "The number of errors, from 1 to 20.") var limit = 5
    @Flag(help: "Prints JSON, as the MCP tool last_errors gives it.") var json = false

    func run() async throws {
        var arguments = ReadTool.arguments(["site": site])
        arguments["limit"] = .int(limit)

        try await ReadTool.run("last_errors", arguments, json: json) { result in
            let errors = ReadTool.list(result["errors"])

            guard !errors.isEmpty else {
                return [ReadTool.text(result["note"]) ?? "No errors."]
            }

            return errors.flatMap { error in
                let heading = [ReadTool.text(error["time"]), ReadTool.text(error["source"]), ReadTool.text(error["level"])].compactMap { $0 }.joined(separator: "  ")
                let trace = ReadTool.list(error["trace"]).compactMap(ReadTool.text).map { "    \($0)" }
                return [heading, "  \(ReadTool.text(error["message"]) ?? "")"] + trace + [""]
            }
        }
    }
}

extension MailCommand {
    struct Wait: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Waits for a mail to an address or with a subject, and shows its codes and links, for example: nexus mail wait --to ann@example.com",
            discussion: "A mail counts from 60 seconds before the command. So run it after the action that sends the mail. With --to, the whole inbox counts. Without --to, only the mail of the site of the current folder counts."
        )

        @Option(help: "The address that gets the mail.") var to: String?
        @Option(help: "A word or a part of the subject.") var subject: String?
        @Option(help: "The number of seconds to wait, at most 50.") var seconds = 30
        @Option(help: "A host or a folder of a site, or all.") var site: String?
        @Flag(help: "Prints JSON, as the MCP tool wait_for_mail gives it.") var json = false

        func run() async throws {
            var arguments = ReadTool.arguments(["to": to, "subject": subject, "site": site])
            arguments["seconds"] = .int(seconds)
            var missing: String?

            try await ReadTool.run("wait_for_mail", arguments, json: json) { result in
                guard result["found"] != .bool(false) else {
                    missing = ReadTool.text(result["message"])
                    return []
                }

                return MailCommand.lines(of: result)
            }

            if let missing {
                FileHandle.standardError.write(Data("\(missing)\n".utf8))
                throw ExitCode.failure
            }
        }
    }

    struct Links: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Shows the links and the codes of a mail. latest is the newest mail of the site of the current folder.")

        @Argument(help: "The id of the mail from nexus mail list, or latest.") var id = "latest"
        @Option(help: "A host or a folder of a site, or all.") var site: String?
        @Flag(help: "Prints JSON, as the MCP tool read_mail gives it.") var json = false

        func run() async throws {
            try await ReadTool.run("read_mail", ReadTool.arguments(["id": id, "site": site]), json: json) { mail in
                MailCommand.lines(of: mail)
            }
        }
    }

    static func lines(of mail: JSONValue) -> [String] {
        var lines = [
            "Mail     \(ReadTool.text(mail["id"]) ?? "")",
            "Subject  \(ReadTool.text(mail["subject"]) ?? "")",
            "To       \(ReadTool.list(mail["to"]).compactMap(ReadTool.text).joined(separator: ", "))",
        ]

        let codes = ReadTool.list(mail["codes"]).compactMap(ReadTool.text)

        if !codes.isEmpty {
            lines.append("Codes    \(codes.joined(separator: ", "))")
        }

        for link in ReadTool.list(mail["links"]) {
            let label = ReadTool.text(link["text"]).map { "\($0): " } ?? ""
            lines.append("Link     \(label)\(ReadTool.text(link["url"]) ?? "")")
        }

        return lines
    }
}
