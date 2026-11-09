import Foundation
import NexusCore
import Testing
@testable import NexusEngine

struct DumpImportTests {
    @Test func replaceTablesDropsEachTableOfTheDumpFirst() throws {
        let result = try run("/usr/bin/sed", ["-E", NexusEngine.replaceTablesFilter], input: """
            CREATE TABLE `users` (
            create table if not exists `orders` (
            INSERT INTO `users` VALUES (1,'CREATE TABLE `x`');
            """)

        #expect(result == """
            DROP TABLE IF EXISTS `users`; CREATE TABLE `users` (
            DROP TABLE IF EXISTS `orders`; CREATE TABLE `orders` (
            INSERT INTO `users` VALUES (1,'CREATE TABLE `x`');
            """)
    }

    @Test func theFiltersOfAnImportWorkTogether() throws {
        let filter = [NexusEngine.importFilter(prefix: nil, toMySQL: true), NexusEngine.replaceTablesFilter].joined(separator: "\n")

        let result = try run("/usr/bin/sed", ["-E", filter], input: """
            USE `production`;
            CREATE TABLE `users` (
            """)

        #expect(result == "DROP TABLE IF EXISTS `users`; CREATE TABLE `users` (")
    }

    @Test func aPlainDumpOfPostgreSQLStaysInItsDatabaseAndNeedsNoRoles() throws {
        let result = try run("/usr/bin/sed", ["-E", NexusEngine.postgresFilter], input: #"""
            SET transaction_timeout = 0;
            \connect production
            CREATE DATABASE production WITH TEMPLATE = template0;
            CREATE TABLE public.users (
            ALTER TABLE public.users OWNER TO forge;
            GRANT ALL ON SCHEMA public TO forge;
            COPY public.users (id) FROM stdin;
            """#)

        #expect(result == """
            CREATE TABLE public.users (
            COPY public.users (id) FROM stdin;
            """)
    }

    @Test func eachKindOfFileGivesTheSQLOfItsDump() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "nexus-dump-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let sql = "CREATE TABLE `users` (id int);\n"
        try Data(sql.utf8).write(to: folder.appending(path: "shop.sql"))
        _ = try run("/bin/bash", ["-c", "cd \"$1\" && /usr/bin/gzip -k shop.sql && /usr/bin/zip -q backup.zip shop.sql.gz && /usr/bin/tar -czf backup.tar.gz shop.sql", "make", folder.path(percentEncoded: false)])

        let cases: [(String, String?)] = [("shop.sql", nil), ("shop.sql.gz", nil), ("backup.zip", "shop.sql.gz"), ("backup.tar.gz", "shop.sql")]

        for (name, dump) in cases {
            let file = folder.appending(path: name).path(percentEncoded: false)
            let container = DumpContainer.of(name)

            if let list = container.listArguments {
                let entries = try run(list[0], Array(list.dropFirst()) + [file]).split(whereSeparator: \.isNewline).map(String.init)
                #expect(DumpArchive.dumps(in: entries) == [dump].compactMap { $0 })
            }

            #expect(try run("/bin/bash", ["-c", container.readerScript(dump: dump), "reader", file] + [dump].compactMap { $0 }) == sql.trimmingCharacters(in: .newlines))
        }
    }

    @Test func aSecondDumpInTheSameSecondGetsItsOwnFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "nexus-trash-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = NexusEngine.freeFile(named: "2026-11-09-195940-mysql-8.4-shop", extension: "sql.gz", in: folder)
        try Data().write(to: first)
        let second = NexusEngine.freeFile(named: "2026-11-09-195940-mysql-8.4-shop", extension: "sql.gz", in: folder)
        try Data().write(to: second.deletingLastPathComponent().appending(path: "\(second.lastPathComponent).partial"))
        let third = NexusEngine.freeFile(named: "2026-11-09-195940-mysql-8.4-shop", extension: "sql.gz", in: folder)

        #expect(first.lastPathComponent == "2026-11-09-195940-mysql-8.4-shop.sql.gz")
        #expect(second.lastPathComponent == "2026-11-09-195940-mysql-8.4-shop-2.sql.gz")
        #expect(third.lastPathComponent == "2026-11-09-195940-mysql-8.4-shop-3.sql.gz")
    }

    private func run(_ program: String, _ arguments: [String], input: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: program)
        process.arguments = arguments
        let output = Pipe()
        let stdin = Pipe()
        process.standardOutput = output
        process.standardInput = stdin
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: Data((input.map { $0 + "\n" } ?? "").utf8))
        try stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}
