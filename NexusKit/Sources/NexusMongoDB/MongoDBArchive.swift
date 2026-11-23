import Foundation
import NexusCore

// The start of a file of mongodump --archive, without its gzip layer. A magic number, a header
// document and one document for each collection come first. The value -1 ends that list. The data
// of the collections follows.
public enum MongoDBArchive {
    public struct Collection: Equatable, Sendable {
        public let database: String
        public let name: String

        public init(database: String, name: String) {
            self.database = database
            self.name = name
        }
    }

    // The start must hold the whole list. A shorter start gives an error, not a short list.
    public static func collections(in start: Data) throws -> [Collection] {
        let bytes = [UInt8](start)
        let magic = DumpFormat.mongoDBMagic

        guard bytes.starts(with: magic) else {
            throw BSONError.invalidDocument
        }

        var position = magic.count
        var collections: [Collection] = []
        var isHeader = true

        while true {
            guard position + 4 <= bytes.count else {
                throw BSONError.invalidDocument
            }

            let size = Int(Int32(littleEndian: bytes[position..<position + 4].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }))

            if size == -1, !isHeader {
                return collections
            }

            guard size >= 5, position + size <= bytes.count else {
                throw BSONError.invalidDocument
            }

            let document = try BSON.decode(Data(bytes[position..<position + size]))
            position += size

            if isHeader {
                isHeader = false
                continue
            }

            guard let database = document["db"]?.string, let name = document["collection"]?.string else {
                throw BSONError.invalidDocument
            }

            collections.append(Collection(database: database, name: name))
        }
    }

    // The databases in the order of the archive.
    public static func databases(of collections: [Collection]) -> [String] {
        collections.map(\.database).reduce(into: []) { names, name in
            if !names.contains(name) {
                names.append(name)
            }
        }
    }
}
