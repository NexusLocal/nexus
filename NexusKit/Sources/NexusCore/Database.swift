import Foundation

// The database servers that Nexus runs. The raw value is the package name in the manifest.
public enum DatabaseKind: String, Codable, Sendable, CaseIterable {
    case mysql
    case mariadb
    case postgresql

    public var displayName: String {
        switch self {
        case .mysql: "MySQL"
        case .mariadb: "MariaDB"
        case .postgresql: "PostgreSQL"
        }
    }

    public var standardPort: Int {
        switch self {
        case .mysql, .mariadb: 3306
        case .postgresql: 5432
        }
    }

    // MySQL and MariaDB use the same protocol and the same tools, so a dump goes from one to
    // the other.
    public var usesMySQLProtocol: Bool {
        self != .postgresql
    }

    public var urlScheme: String {
        usesMySQLProtocol ? "mysql" : "postgresql"
    }
}

// A new database instance gets root without a password (D35). The account root with the
// password root is the one of MAMP PRO. The instances that Nexus made before part 6c of step 6
// have it too.
public struct DatabaseAccount: Codable, Sendable, Equatable {
    public static let standard = DatabaseAccount(user: "root", password: "root")
    public static let newInstance = DatabaseAccount(user: "root", password: "")

    public let user: String
    public let password: String

    public init(user: String, password: String) {
        self.user = user
        self.password = password
    }
}

public enum DatabaseName {
    // MySQL permits 64 characters in a name and PostgreSQL 63. Other characters than these need
    // quotes in every tool, so Nexus refuses them. The tools read a name that starts with - as
    // an option.
    public static func validated(_ name: String) throws -> String {
        guard (1...63).contains(name.count),
              !name.hasPrefix("-"),
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
            throw DatabaseNameError.invalid(name)
        }

        return name
    }
}

public enum DatabaseNameError: Error, Equatable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let name):
            "\(name) is not a database name that Nexus can use. Use 1 to 63 characters: letters, digits, _ and -, and do not start with -."
        }
    }
}
