import Foundation
import NexusRuntime
import NexusSupervisor

public enum NexusRequest: Codable, Sendable, Equatable {
    case status
    case start(service: String)
    case stop(service: String)
    case setPort(service: String, port: Int)
    case available
    case installed
    case install(name: String, line: String)
    case remove(name: String, line: String)
}

public enum NexusResponse: Codable, Sendable, Equatable {
    case done(message: String)
    case services([ServiceStatus])
    case available([ManifestPackage])
    case installed([InstalledRuntime])
    case failure(message: String)
}

public enum NexusMessageCoding {
    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

@objc public protocol NexusDaemonProtocol {
    func handle(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}
