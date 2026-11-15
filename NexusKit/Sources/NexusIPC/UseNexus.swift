import Foundation
import NexusCore

// "Use Nexus…" on the Site screen of a Laravel site (owner, 2026-11-14). Each list holds only the
// keys that change. The passwords of the old .env and of the instance are in the changes, because
// the sheet shows them.
public struct UseNexusInfo: Codable, Sendable, Equatable {
    public let host: String
    public let url: String
    public let appURL: EnvValueChange?
    public let appURLValue: String?
    public let database: UseNexusDatabase?
    public let redis: [EnvValueChange]

    public init(host: String, url: String, appURL: EnvValueChange?, appURLValue: String?, database: UseNexusDatabase?, redis: [EnvValueChange]) {
        self.host = host
        self.url = url
        self.appURL = appURL
        self.appURLValue = appURLValue
        self.database = database
        self.redis = redis
    }
}

public struct UseNexusDatabase: Codable, Sendable, Equatable {
    public let connection: String
    // nil when the connection names no database that Nexus can copy or make.
    public let database: String?
    // The servers of Nexus for the popup. The first one is the choice of Nexus.
    public let choices: [UseNexusChoice]

    public init(connection: String, database: String?, choices: [UseNexusChoice]) {
        self.connection = connection
        self.database = database
        self.choices = choices
    }
}

public struct UseNexusChoice: Codable, Sendable, Equatable {
    public let instance: String
    public let name: String
    public let changes: [EnvValueChange]
    // nil when the instance does not run. Then nexusd checks again before the copy.
    public let databaseExists: Bool?
    // The old server answers, it holds the database, and this instance does not have it.
    public let canCopy: Bool

    public init(instance: String, name: String, changes: [EnvValueChange], databaseExists: Bool?, canCopy: Bool) {
        self.instance = instance
        self.name = name
        self.changes = changes
        self.databaseExists = databaseExists
        self.canCopy = canCopy
    }
}

// What the user confirmed. nexusd refuses when the plan is different now.
public struct UseNexusRequest: Codable, Sendable, Equatable {
    public let host: String
    public let instance: String?
    public let copy: Bool
    public let changes: [EnvValueChange]

    public init(host: String, instance: String?, copy: Bool, changes: [EnvValueChange]) {
        self.host = host
        self.instance = instance
        self.copy = copy
        self.changes = changes
    }
}

extension UseNexusInfo {
    public var noticeTitle: String {
        "The .env of \(host) does not use Nexus"
    }

    // Only APP_URL names the value and the URL of Nexus. More parts name only what differs.
    public var noticeMessage: String {
        let parts = [appURL?.key, database.map { "the database connection \($0.connection)" }, redis.isEmpty ? nil : "Redis"].compactMap { $0 }

        if let appURL, parts.count == 1 {
            let value = appURLValue ?? ""
            return "\(appURL.key) is \(value.isEmpty ? "empty" : value). Nexus serves this site on \(url)."
        }

        let sentence = parts.count == 1
            ? "\(parts[0]) points to another place."
            : "\(EnglishList.joined(parts)) point to other places."

        return "\(sentence.firstLetterUppercased) So the site may not work in Nexus."
    }

    public var sheetTitle: String {
        "Use Nexus for \(host)?"
    }

    // APP_URL, then the database keys of the chosen instance, then Redis. This is also the order
    // of the rows in the sheet.
    public func changes(choosing instance: String?) -> [EnvValueChange] {
        let choice = database?.choices.first { $0.instance == instance }

        return (appURL.map { [$0] } ?? []) + (choice?.changes ?? []) + redis
    }

    // What Nexus did with the database before it changed the .env.
    public enum DatabaseStep: Sendable, Equatable {
        case copied
        case made
        case unchanged
    }

    public static func doneTitle(host: String) -> String {
        "The .env of \(host) uses Nexus now"
    }

    public static func failedTitle(host: String) -> String {
        "The .env of \(host) did not change"
    }

    // server is the name of the instance, for example MySQL 8.4.
    public static func doneMessage(database: String?, server: String?, step: DatabaseStep, keys: Int) -> String {
        let changed = "changed \(Count.text(keys, "key"))."
        let comments = keys == 1 ? "The old value stays as a comment line." : "The old values stay as comment lines."

        guard let database, let server else {
            return "Nexus \(changed) \(comments)"
        }

        switch step {
        case .copied:
            return "Nexus copied \(database) to \(server) and \(changed) \(comments)"
        case .made:
            return "Nexus made the empty database \(database) on \(server) and \(changed) \(comments)"
        case .unchanged:
            return "Nexus \(changed) \(comments)"
        }
    }
}

extension UseNexusChoice {
    public func copyTitle(database: String) -> String {
        "Copy the data of \(database) to \(name)"
    }

    public func copyHelp(database: String) -> String {
        "The old server still runs, and \(database) is not on \(name) yet. The old server does not change."
    }

    // The line in place of the checkbox when Nexus cannot copy. nil when the connection names no
    // database, or when the instance has it already.
    public func emptyDatabaseText(database: String?) -> String? {
        guard let database, databaseExists != true else {
            return nil
        }

        return "Nexus makes the empty database \(database) on \(name)."
    }
}
