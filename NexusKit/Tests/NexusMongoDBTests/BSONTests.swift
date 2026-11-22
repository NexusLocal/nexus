import Foundation
import Testing
@testable import NexusMongoDB

struct BSONTests {
    @Test func aDocumentHasTheBytesOfTheSpecification() throws {
        let document: BSONDocument = ["hello": .string("world")]
        let bytes = Data([0x16, 0, 0, 0, 2] + Array("hello".utf8) + [0, 6, 0, 0, 0] + Array("world".utf8) + [0, 0])

        #expect(try BSON.encode(document) == bytes)
        #expect(try BSON.decode(bytes) == document)
    }

    @Test func eachTypeSurvivesARoundTrip() throws {
        let document: BSONDocument = [
            "double": .double(-1.5),
            "text": .string("café"),
            "document": .document(["a": .int32(-7)]),
            "array": .array([.int32(1), .string("two"), .null]),
            "binary": .binary(Data([0, 1, 255])),
            "id": .objectID(Data(1...12)),
            "yes": .bool(true),
            "no": .bool(false),
            "nothing": .null,
            "small": .int32(.min),
            "large": .int64(.max),
            "date": .other(type: 9, bytes: Data(1...8)),
            "timestamp": .other(type: 17, bytes: Data(1...8)),
            "decimal": .other(type: 19, bytes: Data(1...16)),
            "pattern": .other(type: 11, bytes: Data("a.*\0i\0".utf8)),
            "minKey": .other(type: 255, bytes: Data()),
            "uuid": .other(type: 5, bytes: Data([2, 0, 0, 0, 4, 9, 9])),
        ]

        #expect(try BSON.decode(BSON.encode(document)) == document)
    }

    @Test func aDocumentKeepsTheOrderOfItsKeys() throws {
        var document: BSONDocument = ["z": .int32(1), "a": .int32(2)]
        document["z"] = .int32(3)
        document["m"] = .int32(4)
        document["a"] = nil

        let decoded = try BSON.decode(BSON.encode(document))

        #expect(decoded.elements.map(\.key) == ["z", "m"])
        #expect(decoded["z"] == .int32(3))
    }

    @Test(arguments: [
        [],
        [5, 0, 0, 0],
        [6, 0, 0, 0, 0],
        [4, 0, 0, 0, 0],
        [5, 0, 0, 0, 1],
        [0xFF, 0xFF, 0xFF, 0x7F, 0],
        [0xFF, 0xFF, 0xFF, 0xFF, 0],
        [8, 0, 0, 0, 2, 0x61, 0, 0],
        [12, 0, 0, 0, 2, 0x61, 0, 0xFF, 0xFF, 0xFF, 0x7F, 0],
        [12, 0, 0, 0, 2, 0x61, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0],
        [12, 0, 0, 0, 5, 0x61, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0],
        [8, 0, 0, 0, 0x42, 0x61, 0, 0],
        [7, 0, 0, 0, 10, 0x61, 0x61],
        [5, 0, 0, 0, 0, 0],
    ] as [[UInt8]])
    func brokenBytesGiveAnError(bytes: [UInt8]) {
        #expect(throws: BSONError.invalidDocument) {
            try BSON.decode(Data(bytes))
        }
    }

    @Test func eachCutOfADocumentGivesAnError() throws {
        let bytes = try BSON.encode(["a": .document(["b": .array([.string("c"), .binary(Data(1...9))])]), "d": .int64(5)])

        for length in 0..<bytes.count {
            #expect(throws: BSONError.invalidDocument) {
                try BSON.decode(bytes.prefix(length))
            }
        }
    }

    @Test func tooManyLevelsGiveAnError() throws {
        let deep = (0...BSON.maxDepth).reduce(BSONDocument()) { inner, _ in ["a": .document(inner)] }
        let bytes = try BSON.encode(deep)

        #expect(throws: BSONError.invalidDocument) {
            try BSON.decode(bytes)
        }
    }

    @Test func aKeyWithAZeroByteGivesAnError() {
        #expect(throws: BSONError.invalidKey("a\0b")) {
            try BSON.encode(["a\0b": .null])
        }
    }

    @Test(arguments: [(BSONValue.int32(5), 5), (.int64(5), 5), (.double(5), 5), (.string("5"), nil), (.double(.infinity), nil)] as [(BSONValue, Int64?)])
    func eachKindOfNumberGivesAnInteger(value: BSONValue, number: Int64?) {
        #expect(value.int64 == number)
    }
}
