import Foundation
import Testing
@testable import NexusCore

struct DumpFileTests {
    @Test(arguments: [
        ("shop.sql", DumpContainer.plain),
        ("shop.dump", .plain),
        ("shop.sql.gz", .gzip),
        ("SHOP.SQL.GZ", .gzip),
        ("backup.zip", .zip),
        ("backup.tar", .tar),
        ("backup.tar.gz", .tar),
        ("backup.tgz", .tar),
    ])
    func theNameGivesTheWayToReadTheFile(name: String, container: DumpContainer) {
        #expect(DumpContainer.of("/Users/me/Downloads/\(name)") == container)
    }

    @Test func anArchiveOffersOnlyTheFilesThatCanBeADump() {
        let entries = ["backup/", "backup/shop.sql.gz", "backup/logs.sql", "backup/readme.txt", "__MACOSX/backup/._shop.sql.gz", "backup/._logs.sql", "pg/shop.dump"]

        #expect(DumpArchive.dumps(in: entries) == ["backup/shop.sql.gz", "backup/logs.sql", "pg/shop.dump"])
    }

    @Test func aDumpInAnArchiveThatEndsInGzIsUnpackedTwice() {
        #expect(DumpContainer.zip.readerScript(dump: "shop.sql.gz").hasSuffix("| /usr/bin/gzip -dc"))
        #expect(!DumpContainer.tar.readerScript(dump: "shop.sql").contains("gzip"))
        #expect(DumpContainer.gzip.readerScript(dump: nil) == #"exec /usr/bin/gzip -dc "$1""#)
    }

    @Test(arguments: [
        ("PGDMP\u{01}\u{0E}\u{00}", DumpFormat?.some(.postgresqlCustom)),
        ("--\n-- PostgreSQL database dump\n--\n", .postgresql),
        ("COPY public.users (id, name) FROM stdin;\n1\tAnn\n", .postgresql),
        ("-- MySQL dump 10.13\n", .mysql),
        ("CREATE TABLE `users` (\n", .mysql),
        (") ENGINE=InnoDB;\n", .mysql),
        ("SELECT 1;\n", nil),
    ])
    func theStartOfTheDumpGivesItsKind(start: String, format: DumpFormat?) {
        #expect(DumpFormat.of(start: Data(start.utf8)) == format)
    }

    @Test func aDumpFitsOnlyAnInstanceOfItsKind() {
        #expect(DumpFormat.mysql.fits(.mariadb))
        #expect(DumpFormat.mysql.fits(.mysql))
        #expect(!DumpFormat.mysql.fits(.postgresql))
        #expect(DumpFormat.postgresqlCustom.fits(.postgresql))
        #expect(!DumpFormat.postgresql.fits(.mysql))
    }
}
