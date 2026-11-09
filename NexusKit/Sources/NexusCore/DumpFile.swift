import Foundation

// A dump file and the way to read it (owner, 2026-11-09). A .zip or .tar archive can hold more
// than one dump. Nexus reads a dump through a shell command. So a large file never sits in memory.
public enum DumpContainer: Equatable, Sendable {
    case plain
    case gzip
    case zip
    case tar

    public static func of(_ path: String) -> DumpContainer {
        let name = (path as NSString).lastPathComponent.lowercased()

        if name.hasSuffix(".zip") {
            return .zip
        }

        if name.hasSuffix(".tar") || name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
            return .tar
        }

        return name.hasSuffix(".gz") ? .gzip : .plain
    }

    public var isArchive: Bool {
        self == .zip || self == .tar
    }

    // The command that lists the files of an archive, one on each line.
    public var listArguments: [String]? {
        switch self {
        case .zip: ["/usr/bin/zipinfo", "-1"]
        case .tar: ["/usr/bin/tar", "-tf"]
        case .plain, .gzip: nil
        }
    }

    // A bash script that writes the SQL of the dump to its output. $1 is the file and $2 the dump
    // in the archive. A dump in an archive can itself end in .gz.
    public func readerScript(dump: String?) -> String {
        let unpacked = dump.map { $0.lowercased().hasSuffix(".gz") } == true ? " | /usr/bin/gzip -dc" : ""

        switch self {
        case .plain:
            return #"exec /bin/cat "$1""#
        case .gzip:
            return #"exec /usr/bin/gzip -dc "$1""#
        case .zip:
            return #"set -o pipefail; /usr/bin/unzip -p "$1" "$2""# + unpacked
        case .tar:
            return #"set -o pipefail; /usr/bin/tar -xOf "$1" "$2""# + unpacked
        }
    }
}

public enum DumpArchive {
    static let dumpSuffixes = [".sql", ".sql.gz", ".dump", ".backup", ".pgdump"]

    // The files of an archive that can be a dump. macOS adds a folder __MACOSX and ._ files to a
    // zip file. They are no dumps.
    public static func dumps(in entries: [String]) -> [String] {
        entries.filter { entry in
            let name = (entry as NSString).lastPathComponent.lowercased()

            guard !entry.hasSuffix("/"), !entry.hasPrefix("__MACOSX/"), !name.hasPrefix("._") else {
                return false
            }

            return dumpSuffixes.contains { name.hasSuffix($0) }
        }
    }
}

// What a dump holds. pg_dump -Fc starts with PGDMP. A plain dump of PostgreSQL has its own header,
// COPY ... FROM stdin or the schema pg_catalog. A dump of MySQL or MariaDB has backticks or
// ENGINE=.
public enum DumpFormat: String, Codable, Sendable {
    case mysql
    case postgresql
    case postgresqlCustom = "postgresql_custom"

    public static func of(start: Data) -> DumpFormat? {
        if start.starts(with: Array("PGDMP".utf8)) {
            return .postgresqlCustom
        }

        let text = String(decoding: start, as: UTF8.self)

        if text.contains("PostgreSQL database dump") || text.contains("pg_catalog.") || text.contains(" FROM stdin;") {
            return .postgresql
        }

        if text.contains("`") || text.contains("ENGINE=") || text.contains("MySQL dump") || text.contains("MariaDB dump") {
            return .mysql
        }

        return nil
    }

    public func fits(_ kind: DatabaseKind) -> Bool {
        self == .mysql ? kind.usesMySQLProtocol : kind == .postgresql
    }

    public var displayName: String {
        self == .mysql ? "MySQL or MariaDB" : "PostgreSQL"
    }
}
