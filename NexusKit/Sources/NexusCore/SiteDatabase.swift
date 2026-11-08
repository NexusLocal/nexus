import Foundation

// A database connection of a Laravel site, for the Databases section of the Site screen (owner,
// 2026-11-07). instance is the Nexus instance that holds the database. A connection to another
// server, for example MAMP PRO, has no instance.
public struct SiteDatabase: Codable, Sendable, Equatable {
    public let connection: String
    public let database: String
    public let host: String
    public let port: Int?
    public let instance: String?

    public init(connection: String, database: String, host: String, port: Int?, instance: String?) {
        self.connection = connection
        self.database = database
        self.host = host
        self.port = port
        self.instance = instance
    }
}
