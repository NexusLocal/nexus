import Foundation

// The messages of stdio, one on each line. Only a line feed ends a message. The lines of
// Foundation also end at U+2028. A JSON string can hold that character.
public struct LineReader<Bytes: AsyncSequence>: AsyncSequence where Bytes.Element == UInt8 {
    public typealias Element = String

    let bytes: Bytes

    public init(_ bytes: Bytes) {
        self.bytes = bytes
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var bytes: Bytes.AsyncIterator

        public mutating func next() async throws -> String? {
            var buffer: [UInt8] = []

            while let byte = try await bytes.next() {
                if byte == 0x0A {
                    return String(decoding: buffer, as: UTF8.self)
                }

                buffer.append(byte)
            }

            return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(bytes: bytes.makeAsyncIterator())
    }
}
