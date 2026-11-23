import Foundation
import NexusCore
import Testing
@testable import NexusMongoDB

struct MongoDBArchiveTests {
    private func archive(_ collections: [(String, String)], terminated: Bool = true) throws -> Data {
        var data = Data(DumpFormat.mongoDBMagic)
        data += try BSON.encode(["concurrent_collections": .int32(4), "version": .string("0.1"), "server_version": .string("8.0.38"), "tool_version": .string("100.20.1")])

        for (database, collection) in collections {
            data += try BSON.encode(["db": .string(database), "collection": .string(collection), "metadata": .string("{}"), "size": .int32(0), "type": .string("collection")])
        }

        if terminated {
            data += Data([0xFF, 0xFF, 0xFF, 0xFF])
        }

        return data + Data("body".utf8)
    }

    @Test func theStartOfAnArchiveListsEachCollectionWithItsDatabase() throws {
        let collections = try MongoDBArchive.collections(in: archive([("shop", "orders"), ("shop", "users"), ("logs", "lines")]))

        #expect(collections == [
            MongoDBArchive.Collection(database: "shop", name: "orders"),
            MongoDBArchive.Collection(database: "shop", name: "users"),
            MongoDBArchive.Collection(database: "logs", name: "lines"),
        ])
        #expect(MongoDBArchive.databases(of: collections) == ["shop", "logs"])
    }

    @Test func anArchiveWithoutCollectionsHasAnEmptyList() throws {
        #expect(try MongoDBArchive.collections(in: archive([])).isEmpty)
    }

    @Test func aStartThatEndsBeforeTheEndOfTheListIsAnError() throws {
        let start = try archive([("shop", "orders")], terminated: false).dropLast(4)

        #expect(throws: BSONError.self) {
            try MongoDBArchive.collections(in: Data(start))
        }
    }

    @Test func aFileWithoutTheMagicNumberIsAnError() {
        #expect(throws: BSONError.self) {
            try MongoDBArchive.collections(in: Data("-- MySQL dump".utf8))
        }
    }
}
